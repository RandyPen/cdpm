import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

const specs = import.meta.dir;
const root = resolve(specs, "..");

// These are separate on-chain package families. Give the Pyth Pro branch
// unique names in the legacy resolver while keeping its original addresses.
const pythPro = "0x55300367a2d40813727ccac4ecee977a39fb9cdb46f2e6b2c354b9798f5de2c0";
const wormholeCore = "0x5306f64e312b581766351c07af79c72fcb1cd25147157fdc2f8ad76de9a3fb6a";
const wormholeSimpleMajority = "0x99de5c967d8206ef4b75c0afab3df2a59eb02b05c282821db803831008ac25b4";
const frameworkPackages = new Set(["Sui", "MoveStdlib"]);

const aliasesByAddress: Record<string, Record<string, string>> = {
    [pythPro]: { pyth: "pyth_pro", wormhole: "wormhole_simple_majority" },
    [wormholeSimpleMajority]: { wormhole: "wormhole_simple_majority" },
};

// The old model loader reads inline test and friend declarations on dependencies.
const supportFiles: Record<string, string> = {
    bluefin_spot: "tests/unit/**/*.move",
    token_bridge: "sources/test/**/*.move",
    wormhole: "sources/test/**/*.move",
    wormhole_1: "sources/test/**/*.move",
};

type SourceMap = {
    from_file_path: string;
    module_name: [address: string, name: string];
};

function packageManifest(sourceFile: string): string {
    let directory = dirname(sourceFile);
    while (directory !== dirname(directory)) {
        const manifest = join(directory, "Move.toml");
        if (existsSync(manifest)) return manifest;
        directory = dirname(directory);
    }
    throw new Error(`No Move.toml found for ${sourceFile}`);
}

function moveFiles(directory: string): string[] {
    return readdirSync(directory)
        .filter((file) => file.endsWith(".move"))
        .map((file) => join(directory, file));
}

// Preserve comments and string literals when adapting qualified names.
const moveRewrite = /\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|(@(?:pyth|wormhole)\b|\b(?:pyth|wormhole)\b(?=\s*::))|\bdf::exists(?=\s*\()|\b(u64|u128)::div_ceil(?=\s*\()/g;

function adaptDependency(source: string, name: string, address: string): string {
    const aliases = aliasesByAddress[address];
    const kai = name === "kai_sav" || name === "kai_leverage";
    if (!aliases && !kai) return source;

    const divWidths = new Set<string>();
    const adapted = source.replace(moveRewrite, (token, qualifiedName, width) => {
        if (qualifiedName && aliases) {
            const at = qualifiedName.startsWith("@") ? "@" : "";
            const replacement = aliases[qualifiedName.slice(at.length)];
            return replacement ? at + replacement : token;
        }
        if (kai && token === "df::exists") return "df::exists_";
        if (kai && width) {
            divWidths.add(width);
            return `prover_div_ceil_${width}`;
        }
        return token;
    });

    // Same quotient/remainder expression as std::macros::num_div_ceil.
    const helpers = Array.from(divWidths, (width) =>
        `\nfun prover_div_ceil_${width}(x: ${width}, y: ${width}): ${width} {\n` +
        "    if (x % y == 0) x / y else x / y + 1\n}\n",
    );
    return adapted + helpers.join("");
}

const work = mkdtempSync(join(tmpdir(), "cdpm-prover-"));
try {
    execFileSync("sui", ["move", "build", "--path", root, "--build-env", "mainnet", "--install-dir", work], {
        cwd: work,
        stdio: "inherit",
    });

    const compiled = join(work, "build", "cdpm");
    const packages = join(work, "packages");
    const sourceDependencies = join(compiled, "sources", "dependencies");
    const names = readdirSync(sourceDependencies).filter((name) => !frameworkPackages.has(name));
    const addresses = new Map<string, string>();

    function bind(alias: string, address: string) {
        const previous = addresses.get(alias);
        if (previous !== undefined && previous !== address) {
            throw new Error(`Conflicting Move address for ${alias}: ${previous} and ${address}`);
        }
        addresses.set(alias, address);
    }

    const manifests = new Map<string, string>();
    for (const name of ["cdpm", ...names]) {
        const ownPackage = name === "cdpm";
        const sources = ownPackage ? join(compiled, "sources") : join(sourceDependencies, name);
        const debug = join(compiled, "debug_info", ...(ownPackage ? [] : ["dependencies", name]));
        const files = moveFiles(sources);
        if (files.length === 0) throw new Error(`No compiled source files found for ${name}`);

        const destination = join(packages, name, "sources");
        mkdirSync(destination, { recursive: true });
        const firstMap = JSON.parse(readFileSync(join(debug, basename(files[0], ".move") + ".json"), "utf8")) as SourceMap;
        const originalManifest = packageManifest(firstMap.from_file_path);
        const manifest = Bun.TOML.parse(readFileSync(originalManifest, "utf8")) as {
            package: { edition?: string };
        };
        // An omitted edition denotes legacy Move.
        const edition = manifest.package.edition ?? "legacy";
        manifests.set(name, edition);

        for (const file of files) {
            const fileName = basename(file);
            const map = JSON.parse(readFileSync(join(debug, basename(file, ".move") + ".json"), "utf8")) as SourceMap;
            const address = `0x${map.module_name[0]}`;
            const source = readFileSync(file, "utf8");
            const declaration = /^\s*module\s+([a-zA-Z_]\w*)\s*::/m.exec(source);
            if (!declaration || address !== `0x${firstMap.module_name[0]}`) {
                throw new Error(`Unexpected module address or declaration in ${file}`);
            }
            const namespace = declaration[1];
            bind(aliasesByAddress[address]?.[namespace] ?? namespace, address);
            writeFileSync(join(destination, fileName), adaptDependency(source, name, address));
        }

        const supportPattern = supportFiles[name];
        if (supportPattern) {
            const supportRoot = dirname(originalManifest);
            const support = Array.from(new Bun.Glob(supportPattern).scanSync({ cwd: supportRoot }));
            if (support.length === 0) throw new Error(`No prover support files found for ${name}`);
            for (const path of support) {
                const source = readFileSync(join(supportRoot, path), "utf8");
                const target = join(destination, basename(path));
                writeFileSync(target, adaptDependency(source, name, `0x${firstMap.module_name[0]}`), { flag: "wx" });
            }
        }
    }

    for (const [alias, expected] of Object.entries({
        pyth_pro: pythPro,
        wormhole: wormholeCore,
        wormhole_simple_majority: wormholeSimpleMajority,
    })) {
        if (addresses.get(alias) !== expected) throw new Error(`Unexpected package address for ${alias}`);
    }

    for (const [alias, namespace] of [["scallop_protocol", "protocol"], ["scallop_pool", "spool"]]) {
        const address = addresses.get(namespace);
        if (!address) throw new Error(`Missing linked package for ${namespace}`);
        bind(alias, address);
    }

    const addressTable = Array.from(addresses, ([alias, address]) => `${alias} = "${address}"`).sort().join("\n");
    const dependencyTable = names.map((name) => `${name} = { local = "../${name}" }`).join("\n");
    for (const [name, edition] of manifests) {
        writeFileSync(
            join(packages, name, "Move.toml"),
            `[package]\nname = "${name}"\nedition = "${edition}"\n\n` +
                (name === "cdpm" ? `[dependencies]\n${dependencyTable}\n\n` : "") +
                `[addresses]\n${addressTable}\n`,
        );
    }

    const specPackage = join(work, "specs");
    mkdirSync(specPackage);
    cpSync(join(specs, "sources"), join(specPackage, "sources"), { recursive: true });
    cpSync(join(specs, "Move.toml"), join(specPackage, "Move.toml"));
    execFileSync("sui-prover", ["--path", specPackage, "--skip-fetch-latest-git-deps"], {
        cwd: work,
        stdio: "inherit",
    });
} finally {
    rmSync(work, { recursive: true, force: true });
}
