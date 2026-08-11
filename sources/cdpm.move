module cdpm::cdpm;

use std::type_name;
use std::ascii::String;
use std::option::{Self, Option};

use sui::event;
use sui::vec_set::{Self, VecSet};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::table::{Self, Table};
use sui::clock::{Self, Clock};

use cetusdlmm::pool::{Self, Pool};
use cetusdlmm::position::{Self, Position};
use cetusdlmm::versioned::Versioned;
use cetusdlmm::config::GlobalConfig;

use integer_mate::i32::I32;

use protocol::market::Market;
use protocol::reserve::MarketCoin;
use protocol::version::Version as ScallopVersion;
use protocol::mint;
use protocol::redeem;

use kai_sav::vault as kai_vault;
use kai_sav::kai_leverage_supply_pool as klsp;
use kai_leverage::supply_pool::SupplyPool;

const FEE_DENOMINATOR: u128 = 10000;
const MAX_FEE_RATE: u128 = 5000;

const ENotOwner: u64              = 1001;     // caller is not pm.owner
const ENotAllow: u64              = 1002;     // caller not in agents / access list (or invariant broken)
const EInvalidFeeRate: u64        = 1003;     // admin_set_fee given rate > MAX_FEE_RATE (50%)
const ELendingNotEmpty: u64       = 1004;     // user_close_pm called with non-empty lending Bag
const ENoSuchVault: u64           = 1005;     // pull_from_*_lending called for an absent vault entry
const ENoSuchBalance: u64         = 1006;     // withdraw_from_balance/_fee called for an absent type
const EPositionHasRewards: u64    = 1007;     // user_close_pm called with unclaimed Cetus pool rewards
const EBalanceNotEmpty: u64       = 1008;     // user_close_pm called with non-empty balance Bag
const EFeeNotEmpty: u64           = 1009;     // user_close_pm called with non-empty fee Bag
const EPositionAlreadyExists: u64 = 1010;  // agent_create_position called when position is Some
const ENoPosition: u64            = 1011;  // operation requires position but position is None
const EWrongPool: u64             = 1012;  // agent_create_position called with mismatched pool

// ============ Data Structures ============
public struct AccessList has key {
    id: UID,
    allow: VecSet<address>,
}

public struct AdminCap has key {
    id: UID,
}

public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,
    fee: Bag,
}

public struct PositionManager has key {
    id: UID,
    owner: address,
    agents: VecSet<address>,
    pool_id: ID,
    position: Option<Position>,
    balance: Bag,
    fee: Bag,
    lending: Bag,
}

public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>,
    principal: u64,
}

// Stored in the same `lending: Bag` as ScallopVault. Bag key uses YT's
// type_name so a single underlying T can simultaneously have a ScallopVault
// (key = T) and a KaiVault (key = YT) without collision. YT's TreasuryCap is
// owned by Kai's vault module, so external code cannot forge `Coin<YT>` —
// the type-pin defense matches Scallop's MarketCoin<T> guarantee.
public struct KaiVault<phantom T, phantom YT> has store {
    yt_balance: Balance<YT>,
    principal: u64,
}

public struct GlobalRecord has key {
    id: UID,
    record: Table<address, ID>,
}

public struct Record has key {
    id: UID,
    record: Table<ID, bool>,
}

// ============ Event Structures ============
public struct PositionManagerCreated has copy, drop {
    pm_id: ID,
    owner: address,
    pool_id: ID,
    lower_bin_id: I32,
    upper_bin_id: I32,
    liquidity_shares: vector<u128>,
}

public struct PositionManagerClosed has copy, drop {
    pm_id: ID,
    owner: address,
}

public struct AgentPositionCreated has copy, drop {
    pm_id: ID,
    pool_id: ID,
    lower_bin_id: I32,
    upper_bin_id: I32,
    liquidity_shares: vector<u128>,
}

public struct AgentPositionDestroyed has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,
    coin_type_b: String,
    amount_a: u64,
    amount_b: u64,
}

public struct LiquidityAdded has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    amount_a: u64,
    amount_b: u64,
}

public struct LiquidityRemoved has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    amount_a: u64,
    amount_b: u64,
}

public struct FeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,
    coin_type_b: String,
    amount_a: u64,
    amount_b: u64,
}

public struct RewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,
    amount: u64,
}

public struct ProtocolFeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,
    coin_type_b: String,
    amount_a: u64,
    amount_b: u64,
    fee_a: u64,
    fee_b: u64,
}

public struct ProtocolRewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,
    amount: u64,
    fee_amount: u64,
}

public struct BalanceDeposited has copy, drop {
    pm_id: ID,
    coin_type: String,
    amount: u64,
}

public struct BalanceWithdrawn has copy, drop {
    pm_id: ID,
    coin_type: String,
    amount: u64,
}

public struct UserFeeWithdrawn has copy, drop {
    pm_id: ID,
    coin_type: String,
    amount: u64,
}

public struct AdminFeeCollected has copy, drop {
    fee_house_id: ID,
    coin_type: String,
    amount: u64,
    admin: address,
}

public struct FeeTransferredToBalance has copy, drop {
    pm_id: ID,
    coin_type: String,
    amount: u64,
}

public struct AgentAdded has copy, drop {
    pm_id: ID,
    agent: address,
}

public struct AgentRemoved has copy, drop {
    pm_id: ID,
    agent: address,
}

public struct FeeRateUpdated has copy, drop {
    fee_house_id: ID,
    old_fee_rate: u64,
    new_fee_rate: u64,
}

public struct AccessGranted has copy, drop {
    access_list_id: ID,
    address: address,
}

public struct AccessRevoked has copy, drop {
    access_list_id: ID,
    address: address,
}

public struct AdminTransferred has copy, drop {
    from: address,
    to: address,
}

public struct RecordCreated has copy, drop {
    record_id: ID,
    owner: address,
}

public struct RecordDeleted has copy, drop {
    record_id: ID,
    owner: address,
}

public struct ProtocolLiquidityAdded has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    amount_a: u64,
    amount_b: u64,
}

public struct ProtocolLiquidityRemoved has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    amount_a: u64,
    amount_b: u64,
}

public struct AgentLiquidityAdded has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    amount_a: u64,
    amount_b: u64,
}

public struct AgentLiquidityRemoved has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    amount_a: u64,
    amount_b: u64,
}

public struct AgentFeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,
    coin_type_b: String,
    amount_a: u64,
    amount_b: u64,
}

public struct AgentRewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,
    amount: u64,
}

public struct ScallopSupplied has copy, drop {
    pm_id: ID,
    coin_type: String,
    deposit_amount: u64,
    market_coin_minted: u64,
}

public struct ScallopRedeemed has copy, drop {
    pm_id: ID,
    coin_type: String,
    market_coin_redeemed: u64,
    redeemed_amount: u64,
    principal_portion: u64,
    interest: u64,
    fee_amount: u64,
}

public struct KaiSupplied has copy, drop {
    pm_id: ID,
    coin_type: String,
    yt_type: String,
    deposit_amount: u64,
    yt_minted: u64,
}

public struct KaiRedeemed has copy, drop {
    pm_id: ID,
    coin_type: String,
    yt_type: String,
    yt_burned: u64,
    redeemed_amount: u64,
    principal_portion: u64,
    interest: u64,
    fee_amount: u64,
}

fun init(ctx: &mut TxContext) {
    let deployer = ctx.sender();
    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, deployer);
    let fee_house = FeeHouse {
        id: object::new(ctx),
        fee_rate: 2000,
        fee: bag::new(ctx),
    };
    transfer::share_object(fee_house);
    let access = AccessList {
        id: object::new(ctx),
        allow: vec_set::empty(),
    };
    transfer::share_object(access);
    let global_record = GlobalRecord {
        id: object::new(ctx),
        record: table::new(ctx),
    };
    transfer::share_object(global_record);
}

public fun register_and_return_record(
    global_record: &mut GlobalRecord,
    ctx: &mut TxContext,
): Record {
    let record = Record {
        id: object::new(ctx),
        record: table::new<ID, bool>(ctx),
    };
    let record_id = object::id(&record);
    table::add(&mut global_record.record, ctx.sender(), record_id);

    event::emit(RecordCreated {
        record_id,
        owner: ctx.sender(),
    });

    record
}

public fun transfer_record(
    record: Record,
    ctx: &TxContext,
) {
    transfer::transfer(record, ctx.sender());
}

public fun unregister_record(
    global_record: &mut GlobalRecord,
    record: Record,
    ctx: &TxContext,
) {
    let Record { id, record } = record;
    record.destroy_empty();
    id.delete();
    let record_id = table::remove(&mut global_record.record, ctx.sender());

    event::emit(RecordDeleted {
        record_id,
        owner: ctx.sender(),
    });
}

public fun user_deposit_liquidity<CoinTypeA, CoinTypeB>(
    record: &mut Record,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a: &mut Coin<CoinTypeA>,
    coin_b: &mut Coin<CoinTypeB>,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    let position = open_position_private<CoinTypeA, CoinTypeB>(
        pool, coin_a, coin_b, bins, amounts_a, amounts_b,
        config, versioned, clk, ctx,
    );
    let lower_bin_id = position::lower_bin_id(&position);
    let upper_bin_id = position::upper_bin_id(&position);
    let liquidity_shares = position::liquidity_shares(&position);
    let pool_id = object::id(pool);
    let pm = PositionManager {
        id: object::new(ctx),
        owner: ctx.sender(),
        agents: vec_set::empty(),
        pool_id,
        position: option::some(position),
        balance: bag::new(ctx),
        fee: bag::new(ctx),
        lending: bag::new(ctx),
    };
    let pm_id = object::id(&pm);
    table::add(&mut record.record, pm_id, true);
    transfer::share_object(pm);

    event::emit(PositionManagerCreated {
        pm_id,
        owner: ctx.sender(),
        pool_id,
        lower_bin_id,
        upper_bin_id,
        liquidity_shares,
    });
}

public fun user_deposit_position(
    record: &mut Record,
    position: Position,
    ctx: &mut TxContext,
) {
    let lower_bin_id = position::lower_bin_id(&position);
    let upper_bin_id = position::upper_bin_id(&position);
    let liquidity_shares = position::liquidity_shares(&position);
    let pool_id = position::pool_id(&position);
    let pm = PositionManager {
        id: object::new(ctx),
        owner: ctx.sender(),
        agents: vec_set::empty(),
        pool_id,
        position: option::some(position),
        balance: bag::new(ctx),
        fee: bag::new(ctx),
        lending: bag::new(ctx),
    };
    let pm_id = object::id(&pm);
    table::add(&mut record.record, pm_id, true);
    transfer::share_object(pm);

    event::emit(PositionManagerCreated {
        pm_id,
        owner: ctx.sender(),
        pool_id,
        lower_bin_id,
        upper_bin_id,
        liquidity_shares,
    });
}

public fun user_add_liquidity_to_position<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a: &mut Coin<CoinTypeA>,
    coin_b: &mut Coin<CoinTypeB>,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let bins_copy = bins;
    let (amount_a, amount_b) = add_liquidity_private(
        pm,
        pool,
        coin_a,
        coin_b,
        bins,
        amounts_a,
        amounts_b,
        config,
        versioned,
        clk,
        ctx,
    );

    event::emit(LiquidityAdded {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins: bins_copy,
        amount_a,
        amount_b,
    });
}

public fun user_add_liquidity_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
    ctx: &TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let amount = coin.value();
    add_to_balance(pm, coin);

    event::emit(BalanceDeposited {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        amount,
    });
}

public fun user_remove_liquidity_from_position<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let (balance_a, balance_b) = pool::remove_liquidity(
        pool,
        pos,
        bins,
        liquidity_shares,
        config,
        versioned,
        clk,
        ctx,
    );
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();

    event::emit(LiquidityRemoved {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins,
        liquidity_shares,
        amount_a,
        amount_b,
    });

    (balance_a.into_coin(ctx), balance_b.into_coin(ctx))
}

public fun user_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        pos,
        config,
        versioned,
        ctx,
    );
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();

    event::emit(FeeCollected {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        coin_type_a: type_name::with_defining_ids<CoinTypeA>().into_string(),
        coin_type_b: type_name::with_defining_ids<CoinTypeB>().into_string(),
        amount_a,
        amount_b,
    });

    (balance_a.into_coin(ctx), balance_b.into_coin(ctx))
}

public fun user_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
): (Coin<RewardType>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        pos,
        config,
        versioned,
        ctx,
    );
    let amount = balance_reward.value();

    event::emit(RewardCollected {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        coin_type: type_name::with_defining_ids<RewardType>().into_string(),
        amount,
    });

    balance_reward.into_coin(ctx)
}

public fun user_remove_liquidity_from_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let coin = withdraw_from_balance<T>(pm, amount, ctx);
    let actual_amount = coin.value();

    event::emit(BalanceWithdrawn {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        amount: actual_amount,
    });

    coin
}

public fun user_withdraw_fee<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let coin = withdraw_from_fee<T>(pm, amount, ctx);
    let actual_amount = coin.value();

    event::emit(UserFeeWithdrawn {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        amount: actual_amount,
    });

    coin
}

public fun user_insert_agent(
    pm: &mut PositionManager,
    agent: address,
    ctx: &TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    vec_set::insert(&mut pm.agents, agent);

    event::emit(AgentAdded {
        pm_id: object::id(pm),
        agent,
    });
}

public fun user_remove_agent(
    pm: &mut PositionManager,
    agent: address,
    ctx: &TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    vec_set::remove(&mut pm.agents, &agent);

    event::emit(AgentRemoved {
        pm_id: object::id(pm),
        agent,
    });
}

#[allow(lint(self_transfer))]
public fun user_close_pm<CoinTypeA, CoinTypeB>(
    record: &mut Record,
    pm: PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let pm_id = object::id(&pm);
    table::remove<ID, bool>(&mut record.record, pm_id);

    // Drain-precondition asserts up front so the diagnostic is a cdpm error
    // code (not the framework's generic EBagNotEmpty / Cetus's
    // EPositionRewardNotZero from inside close_position_cert).
    assert!(bag::is_empty(&pm.balance), EBalanceNotEmpty);
    assert!(bag::is_empty(&pm.fee), EFeeNotEmpty);
    assert!(bag::is_empty(&pm.lending), ELendingNotEmpty);

    let PositionManager { id, owner, agents: _, pool_id: _, mut position, balance, fee, lending } = pm;

    if (option::is_some(&position)) {
        // Reward residual check: Cetus's destroy_close_position_cert aborts
        // with EPositionRewardNotZero if any reward type remains uncollected.
        // We duplicate the check here against the live PositionInfo so the
        // abort surfaces as a cdpm error code (EPositionHasRewards) before
        // the close_position call happens.
        let pos_id = object::id(option::borrow(&position));
        let manager_ref = pool::position_manager<CoinTypeA, CoinTypeB>(pool);
        let pos_info = position::borrow_position_info(manager_ref, pos_id);
        let rewards = position::info_rewards(pos_info);
        let n = vector::length(rewards);
        let mut i = 0;
        while (i < n) {
            assert!(*vector::borrow(rewards, i) == 0, EPositionHasRewards);
            i = i + 1;
        };

        let pos = option::extract(&mut position);
        let (cert, balance_a, balance_b) = pool::close_position<CoinTypeA, CoinTypeB>(
            pool,
            pos,
            config,
            versioned,
            clk,
            ctx,
        );
        pool::destroy_close_position_cert(cert, versioned);
        transfer::public_transfer(balance_a.into_coin(ctx), ctx.sender());
        transfer::public_transfer(balance_b.into_coin(ctx), ctx.sender());
        option::destroy_none(position);
    } else {
        option::destroy_none(position);
    };

    balance.destroy_empty();
    fee.destroy_empty();
    lending.destroy_empty();
    id.delete();

    event::emit(PositionManagerClosed {
        pm_id,
        owner,
    });
}

public fun protocol_add_liquidity<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    amount_a: u64,
    amount_b: u64,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    assert!(vec_set::is_empty<address>(&pm.agents), ENotAllow);
    let mut coin_a = withdraw_from_balance<CoinTypeA>(pm, amount_a, ctx);
    let mut coin_b = withdraw_from_balance<CoinTypeB>(pm, amount_b, ctx);
    let bins_copy = bins;
    let (used_a, used_b) = add_liquidity_private(
        pm,
        pool,
        &mut coin_a,
        &mut coin_b,
        bins,
        amounts_a,
        amounts_b,
        config,
        versioned,
        clk,
        ctx,
    );
    add_to_balance<CoinTypeA>(pm, coin_a);
    add_to_balance<CoinTypeB>(pm, coin_b);

    event::emit(ProtocolLiquidityAdded {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins: bins_copy,
        amount_a: used_a,
        amount_b: used_b,
    });
}

public fun protocol_remove_liquidity<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    assert!(vec_set::is_empty<address>(&pm.agents), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let (balance_a, balance_b) = pool::remove_liquidity(
        pool,
        pos,
        bins,
        liquidity_shares,
        config,
        versioned,
        clk,
        ctx,
    );
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();
    add_to_balance<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_balance<CoinTypeB>(pm, balance_b.into_coin(ctx));

    event::emit(ProtocolLiquidityRemoved {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins,
        liquidity_shares,
        amount_a,
        amount_b,
    });
}

public fun protocol_collect_fee<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    assert!(vec_set::is_empty<address>(&pm.agents), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let (mut balance_a, mut balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        pos,
        config,
        versioned,
        ctx,
    );
    let fee_a = take_fee<CoinTypeA>(&mut balance_a, fee_house);
    let fee_b = take_fee<CoinTypeB>(&mut balance_b, fee_house);
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();
    add_to_fee<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_fee<CoinTypeB>(pm, balance_b.into_coin(ctx));
    
    event::emit(ProtocolFeeCollected {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        coin_type_a: type_name::with_defining_ids<CoinTypeA>().into_string(),
        coin_type_b: type_name::with_defining_ids<CoinTypeB>().into_string(),
        amount_a,
        amount_b,
        fee_a,
        fee_b,
    });
}

public fun protocol_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    assert!(vec_set::is_empty<address>(&pm.agents), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let mut balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        pos,
        config,
        versioned,
        ctx,
    );
    let fee_amount = take_fee<RewardType>(&mut balance_reward, fee_house);
    let amount = balance_reward.value();
    add_to_fee<RewardType>(pm, balance_reward.into_coin(ctx));
    
    event::emit(ProtocolRewardCollected {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        coin_type: type_name::with_defining_ids<RewardType>().into_string(),
        amount,
        fee_amount,
    });
}

public fun protocol_transfer_fee_to_balance<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    assert!(vec_set::is_empty<address>(&pm.agents), ENotAllow);
    let fee = withdraw_from_fee<T>(pm, amount, ctx);
    let actual_amount = fee.value();
    add_to_balance<T>(pm, fee);

    event::emit(FeeTransferredToBalance {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        amount: actual_amount,
    });
}

public fun agent_add_liquidity<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    amount_a: u64,
    amount_b: u64,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    let mut coin_a = withdraw_from_balance<CoinTypeA>(pm, amount_a, ctx);
    let mut coin_b = withdraw_from_balance<CoinTypeB>(pm, amount_b, ctx);
    let bins_copy = bins;
    let (used_a, used_b) = add_liquidity_private(
        pm,
        pool,
        &mut coin_a,
        &mut coin_b,
        bins,
        amounts_a,
        amounts_b,
        config,
        versioned,
        clk,
        ctx,
    );
    add_to_balance<CoinTypeA>(pm, coin_a);
    add_to_balance<CoinTypeB>(pm, coin_b);

    event::emit(AgentLiquidityAdded {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins: bins_copy,
        amount_a: used_a,
        amount_b: used_b,
    });
}

public fun agent_remove_liquidity<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let (balance_a, balance_b) = pool::remove_liquidity(
        pool,
        pos,
        bins,
        liquidity_shares,
        config,
        versioned,
        clk,
        ctx,
    );
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();
    add_to_balance<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_balance<CoinTypeB>(pm, balance_b.into_coin(ctx));

    event::emit(AgentLiquidityRemoved {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins,
        liquidity_shares,
        amount_a,
        amount_b,
    });
}

public fun agent_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        pos,
        config,
        versioned,
        ctx,
    );
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();
    add_to_fee<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_fee<CoinTypeB>(pm, balance_b.into_coin(ctx));

    event::emit(AgentFeeCollected {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        coin_type_a: type_name::with_defining_ids<CoinTypeA>().into_string(),
        coin_type_b: type_name::with_defining_ids<CoinTypeB>().into_string(),
        amount_a,
        amount_b,
    });
}

public fun agent_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        pos,
        config,
        versioned,
        ctx,
    );
    let amount = balance_reward.value();
    add_to_fee<RewardType>(pm, balance_reward.into_coin(ctx));

    event::emit(AgentRewardCollected {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        coin_type: type_name::with_defining_ids<RewardType>().into_string(),
        amount,
    });
}

public fun agent_transfer_fee_to_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    let fee = withdraw_from_fee<T>(pm, amount, ctx);
    let actual_amount = fee.value();
    add_to_balance<T>(pm, fee);

    event::emit(FeeTransferredToBalance {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        amount: actual_amount,
    });
}

// ============ Agent Position Lifecycle ============

public fun agent_create_position<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    assert!(option::is_none(&pm.position), EPositionAlreadyExists);
    assert!(object::id(pool) == pm.pool_id, EWrongPool);

    // Calculate total amounts needed from amounts vectors
    let mut total_a = 0u64;
    let mut total_b = 0u64;
    let n = vector::length(&amounts_a);
    let mut i = 0;
    while (i < n) {
        total_a = total_a + *vector::borrow(&amounts_a, i);
        total_b = total_b + *vector::borrow(&amounts_b, i);
        i = i + 1;
    };

    // Withdraw from balance
    let mut coin_a = withdraw_from_balance<CoinTypeA>(pm, total_a, ctx);
    let mut coin_b = withdraw_from_balance<CoinTypeB>(pm, total_b, ctx);

    // Open position
    let position = open_position_private<CoinTypeA, CoinTypeB>(
        pool, &mut coin_a, &mut coin_b, bins, amounts_a, amounts_b,
        config, versioned, clk, ctx,
    );

    // Return unused coins to balance
    add_to_balance<CoinTypeA>(pm, coin_a);
    add_to_balance<CoinTypeB>(pm, coin_b);

    let lower_bin_id = position::lower_bin_id(&position);
    let upper_bin_id = position::upper_bin_id(&position);
    let liquidity_shares = position::liquidity_shares(&position);
    let pool_id = pm.pool_id;

    option::fill(&mut pm.position, position);

    event::emit(AgentPositionCreated {
        pm_id: object::id(pm),
        pool_id,
        lower_bin_id,
        upper_bin_id,
        liquidity_shares,
    });
}

public fun agent_destroy_position<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    assert!(option::is_some(&pm.position), ENoPosition);

    // Reward residual check: Cetus's destroy_close_position_cert aborts with
    // EPositionRewardNotZero if any reward type remains uncollected. We
    // duplicate the check here against the live PositionInfo so the abort
    // surfaces as a cdpm error code (EPositionHasRewards) before the
    // close_position call happens.
    let pos_id = object::id(option::borrow(&pm.position));
    let manager_ref = pool::position_manager<CoinTypeA, CoinTypeB>(pool);
    let pos_info = position::borrow_position_info(manager_ref, pos_id);
    let rewards = position::info_rewards(pos_info);
    let n = vector::length(rewards);
    let mut i = 0;
    while (i < n) {
        assert!(*vector::borrow(rewards, i) == 0, EPositionHasRewards);
        i = i + 1;
    };

    let pool_id = pm.pool_id;
    let position = option::extract(&mut pm.position);

    let (cert, balance_a, balance_b) = pool::close_position<CoinTypeA, CoinTypeB>(
        pool,
        position,
        config,
        versioned,
        clk,
        ctx,
    );
    pool::destroy_close_position_cert(cert, versioned);

    let amount_a = balance_a.value();
    let amount_b = balance_b.value();
    add_to_balance<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_balance<CoinTypeB>(pm, balance_b.into_coin(ctx));

    event::emit(AgentPositionDestroyed {
        pm_id: object::id(pm),
        pool_id,
        coin_type_a: type_name::with_defining_ids<CoinTypeA>().into_string(),
        coin_type_b: type_name::with_defining_ids<CoinTypeB>().into_string(),
        amount_a,
        amount_b,
    });
}

// ============ Admin Functions ============
public fun admin_transfer(
    admin_cap: AdminCap,
    to: address,
    ctx: &TxContext,
) {
    let from = ctx.sender();
    transfer::transfer(admin_cap, to);

    event::emit(AdminTransferred {
        from,
        to,
    });
}

public fun admin_set_fee(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    fee_rate: u64,
) {
    assert!((fee_rate as u128) <= MAX_FEE_RATE, EInvalidFeeRate);
    let old_fee_rate = fee_house.fee_rate;
    fee_house.fee_rate = fee_rate;

    event::emit(FeeRateUpdated {
        fee_house_id: object::id(fee_house),
        old_fee_rate,
        new_fee_rate: fee_rate,
    });
}

public fun admin_collect_fee_return_coin<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    ctx: &mut TxContext,
): Coin<T> {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    let coin: Coin<T> = bag::remove<String, Balance<T>>(&mut fee_house.fee, coin_type).into_coin(ctx);
    let amount = coin.value();

    event::emit(AdminFeeCollected {
        fee_house_id: object::id(fee_house),
        coin_type,
        amount,
        admin: ctx.sender(),
    });

    coin
}

#[allow(lint(self_transfer))]
public fun admin_collect_fee<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    ctx: &mut TxContext,
) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    let coin: Coin<T> = bag::remove<String, Balance<T>>(&mut fee_house.fee, coin_type).into_coin(ctx);
    let amount = coin.value();

    event::emit(AdminFeeCollected {
        fee_house_id: object::id(fee_house),
        coin_type,
        amount,
        admin: ctx.sender(),
    });

    transfer::public_transfer(coin, ctx.sender());
}

public fun admin_insert_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
) {
    vec_set::insert(&mut access.allow, bot);

    event::emit(AccessGranted {
        access_list_id: object::id(access),
        address: bot,
    });
}

public fun admin_remove_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
) {
    vec_set::remove(&mut access.allow, &bot);

    event::emit(AccessRevoked {
        access_list_id: object::id(access),
        address: bot,
    });
}

fun open_position_private<CoinTypeA, CoinTypeB>(
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a: &mut Coin<CoinTypeA>,
    coin_b: &mut Coin<CoinTypeB>,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
): Position {
    let (mut position, open_position_cert) = pool::open_position(
        pool,
        bins,
        amounts_a,
        amounts_b,
        config,
        versioned,
        clk,
        ctx,
    );
    let (amount_a, amount_b) = open_position_cert.open_cert_amounts();
    let (balance_a, balance_b) = (
        coin_a.split(amount_a, ctx).into_balance(),
        coin_b.split(amount_b, ctx).into_balance(),
    );
    pool::repay_open_position(
        pool,
        &mut position,
        open_position_cert,
        balance_a,
        balance_b,
        versioned,
    );
    position
}

fun add_liquidity_private<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a: &mut Coin<CoinTypeA>,
    coin_b: &mut Coin<CoinTypeB>,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {
    assert!(option::is_some(&pm.position), ENoPosition);
    let pos = option::borrow_mut(&mut pm.position);
    let add_liquidity_cert = pool::add_liquidity(
        pool,
        pos,
        bins,
        amounts_a,
        amounts_b,
        config,
        versioned,
        clk,
        ctx,
    );
    let (amount_a, amount_b) = add_liquidity_cert.amounts();
    let (balance_a, balance_b) = (
        coin_a.split(amount_a, ctx).into_balance(),
        coin_b.split(amount_b, ctx).into_balance(),
    );
    pool::repay_add_liquidity(
        pool,
        pos,
        add_liquidity_cert,
        balance_a,
        balance_b,
        versioned,
    );
    (amount_a, amount_b)
}

fun add_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
) {
    if (coin.value() == 0) { coin.destroy_zero(); return };
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, Balance<T>>(&pm.balance, coin_type)) {
        balance::join<T>(bag::borrow_mut(&mut pm.balance, coin_type), coin.into_balance());
    } else {
        bag::add<String, Balance<T>>(&mut pm.balance, coin_type, coin.into_balance());
    };
}

fun withdraw_from_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    if (amount == 0) return coin::zero<T>(ctx);
    let coin_type = type_name::with_defining_ids<T>().into_string();
    assert!(bag::contains_with_type<String, Balance<T>>(&pm.balance, coin_type), ENoSuchBalance);
    let balance_bm = bag::borrow_mut<String, Balance<T>>(&mut pm.balance, coin_type);
    let balance_amount = balance::value<T>(balance_bm);
    if (amount >= balance_amount) {
        bag::remove<String, Balance<T>>(&mut pm.balance, coin_type).into_coin(ctx)
    } else {
        balance::split<T>(bag::borrow_mut(&mut pm.balance, coin_type), amount).into_coin(ctx)
    }
}

fun add_to_fee<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
) {
    if (coin.value() == 0) { coin.destroy_zero(); return };
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, Balance<T>>(&pm.fee, coin_type)) {
        balance::join<T>(bag::borrow_mut(&mut pm.fee, coin_type), coin.into_balance());
    } else {
        bag::add<String, Balance<T>>(&mut pm.fee, coin_type, coin.into_balance());
    };
}

fun withdraw_from_fee<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    if (amount == 0) return coin::zero<T>(ctx);
    let coin_type = type_name::with_defining_ids<T>().into_string();
    assert!(bag::contains_with_type<String, Balance<T>>(&pm.fee, coin_type), ENoSuchBalance);
    let balance_bm = bag::borrow_mut<String, Balance<T>>(&mut pm.fee, coin_type);
    let balance_amount = balance::value<T>(balance_bm);
    if (amount >= balance_amount) {
        bag::remove<String, Balance<T>>(&mut pm.fee, coin_type).into_coin(ctx)
    } else {
        balance::split<T>(bag::borrow_mut(&mut pm.fee, coin_type), amount).into_coin(ctx)
    }
}

/// Takes `fee_house.fee_rate / FEE_DENOMINATOR` of the entire `balance_in` as
/// protocol fee and routes it to `FeeHouse`. Returns the raw `fee_amount`
/// taken (0 if the cut rounds to zero). For full-amount-billable income —
/// DLMM swap fees, reward claims. **Do NOT use on lending redeem paths**:
/// `*_finish_redeem` charges the fee only on `interest = redeemed − principal`
/// and keeps its inline carve-out (see scallop_finish_redeem / kai_finish_redeem).
fun take_fee<T>(
    balance_in: &mut Balance<T>,
    fee_house: &mut FeeHouse,
): u64 {
    let amount_in = balance::value<T>(balance_in);
    let fee_amount = (((amount_in as u128) * (fee_house.fee_rate as u128) / FEE_DENOMINATOR) as u64);
    if (fee_amount == 0) { return 0 };
    let fee = balance::split<T>(balance_in, fee_amount);
    deposit_into_fee_house<T>(fee_house, fee);
    fee_amount
}

fun deposit_into_fee_house<T>(
    fee_house: &mut FeeHouse,
    fee: Balance<T>,
) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, Balance<T>>(&fee_house.fee, coin_type)) {
        balance::join<T>(bag::borrow_mut(&mut fee_house.fee, coin_type), fee);
    } else {
        bag::add<String, Balance<T>>(&mut fee_house.fee, coin_type, fee);
    };
}

fun assert_caller_authorized(
    access: &AccessList,
    pm: &PositionManager,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    let is_owner = pm.owner == sender;
    let is_agent = vec_set::contains<address>(&pm.agents, &sender);
    let is_protocol = vec_set::contains<address>(&access.allow, &sender)
        && vec_set::is_empty<address>(&pm.agents);
    assert!(is_owner || is_agent || is_protocol, ENotAllow);
}

fun add_to_scallop_lending<T>(
    pm: &mut PositionManager,
    scoin: Balance<MarketCoin<T>>,
    principal_added: u64,
) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, ScallopVault<T>>(&pm.lending, coin_type)) {
        let vault = bag::borrow_mut<String, ScallopVault<T>>(&mut pm.lending, coin_type);
        balance::join<MarketCoin<T>>(&mut vault.scoin, scoin);
        vault.principal = vault.principal + principal_added;
    } else {
        bag::add<String, ScallopVault<T>>(
            &mut pm.lending,
            coin_type,
            ScallopVault { scoin, principal: principal_added },
        );
    };
}

fun pull_from_scallop_lending<T>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<MarketCoin<T>>, u64) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    assert!(bag::contains_with_type<String, ScallopVault<T>>(&pm.lending, coin_type), ENoSuchVault);
    let total_scoin = balance::value<MarketCoin<T>>(
        &bag::borrow<String, ScallopVault<T>>(&pm.lending, coin_type).scoin,
    );
    if (want_amount >= total_scoin) {
        let ScallopVault { scoin, principal } =
            bag::remove<String, ScallopVault<T>>(&mut pm.lending, coin_type);
        (scoin, principal)
    } else {
        let vault = bag::borrow_mut<String, ScallopVault<T>>(&mut pm.lending, coin_type);
        let principal_portion = (((vault.principal as u128) * (want_amount as u128)
            / (total_scoin as u128)) as u64);
        vault.principal = vault.principal - principal_portion;
        let s_balance = balance::split<MarketCoin<T>>(&mut vault.scoin, want_amount);
        (s_balance, principal_portion)
    }
}

// ============ Scallop Lending Public API ============
//
// Direct integration: cdpm calls `protocol::mint::mint` / `protocol::redeem::redeem`
// itself. Both functions internally call `accrue_interest_for_market` as their
// first step, so the balance-sheet read after them is fresh by construction.
// Returned coin flows straight into PM storage; no PTB-supplied coin to validate.

public fun scallop_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    version: &ScallopVersion,
    market: &mut Market,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_caller_authorized(access, pm, ctx);
    let coin: Coin<T> = withdraw_from_balance<T>(pm, amount, ctx);
    let actual = coin.value();
    let scoin = mint::mint<T>(version, market, coin, clock, ctx);
    let scoin_amount = scoin.value();
    add_to_scallop_lending<T>(pm, scoin.into_balance(), actual);

    event::emit(ScallopSupplied {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        deposit_amount: actual,
        market_coin_minted: scoin_amount,
    });
}

public fun scallop_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    version: &ScallopVersion,
    market: &mut Market,
    scoin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_caller_authorized(access, pm, ctx);
    let (s_balance, principal_portion) = pull_from_scallop_lending<T>(pm, scoin_amount);
    let scoin_burned = balance::value<MarketCoin<T>>(&s_balance);
    let underlying = redeem::redeem<T>(version, market, s_balance.into_coin(ctx), clock, ctx);
    let redeemed_amount = underlying.value();
    let mut underlying_balance = underlying.into_balance();

    let (interest, fee_amount) = if (redeemed_amount > principal_portion) {
        let interest = redeemed_amount - principal_portion;
        let fee_amount = (((interest as u128) * (fee_house.fee_rate as u128)
            / FEE_DENOMINATOR) as u64);
        if (fee_amount > 0) {
            let fee_balance = balance::split<T>(&mut underlying_balance, fee_amount);
            deposit_into_fee_house<T>(fee_house, fee_balance);
        };
        (interest, fee_amount)
    } else {
        (0, 0)
    };

    add_to_balance<T>(pm, underlying_balance.into_coin(ctx));

    event::emit(ScallopRedeemed {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        market_coin_redeemed: scoin_burned,
        redeemed_amount,
        principal_portion,
        interest,
        fee_amount,
    });
}

// ============ Kai SAV Lending — direct, single-shot ============

fun add_to_kai_lending<T, YT>(
    pm: &mut PositionManager,
    yt_balance: Balance<YT>,
    principal_added: u64,
) {
    let key = type_name::with_defining_ids<YT>().into_string();
    if (bag::contains_with_type<String, KaiVault<T, YT>>(&pm.lending, key)) {
        let v = bag::borrow_mut<String, KaiVault<T, YT>>(&mut pm.lending, key);
        balance::join<YT>(&mut v.yt_balance, yt_balance);
        v.principal = v.principal + principal_added;
    } else {
        bag::add<String, KaiVault<T, YT>>(
            &mut pm.lending,
            key,
            KaiVault { yt_balance, principal: principal_added },
        );
    };
}

fun pull_from_kai_lending<T, YT>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<YT>, u64) {
    let key = type_name::with_defining_ids<YT>().into_string();
    assert!(bag::contains_with_type<String, KaiVault<T, YT>>(&pm.lending, key), ENoSuchVault);
    let total_yt = balance::value<YT>(
        &bag::borrow<String, KaiVault<T, YT>>(&pm.lending, key).yt_balance,
    );
    if (want_amount >= total_yt) {
        let KaiVault { yt_balance, principal } =
            bag::remove<String, KaiVault<T, YT>>(&mut pm.lending, key);
        (yt_balance, principal)
    } else {
        let v = bag::borrow_mut<String, KaiVault<T, YT>>(&mut pm.lending, key);
        let principal_portion = (((v.principal as u128) * (want_amount as u128)
            / (total_yt as u128)) as u64);
        v.principal = v.principal - principal_portion;
        let yt_split = balance::split<YT>(&mut v.yt_balance, want_amount);
        (yt_split, principal_portion)
    }
}

public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_caller_authorized(access, pm, ctx);
    let coin: Coin<T> = withdraw_from_balance<T>(pm, amount, ctx);
    let actual = coin.value();
    let yt_balance = kai_vault::deposit<T, YT>(vault, coin.into_balance(), clock);
    let yt_amount = balance::value<YT>(&yt_balance);
    add_to_kai_lending<T, YT>(pm, yt_balance, actual);

    event::emit(KaiSupplied {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        yt_type: type_name::with_defining_ids<YT>().into_string(),
        deposit_amount: actual,
        yt_minted: yt_amount,
    });
}

// Single-shot redeem covering Kai's two-phase withdrawal flow:
//   vault::withdraw → klsp::withdraw → vault::redeem_withdraw_ticket
// All inline; no hot potato exposed to the PTB. Generic over the
// kai_leverage_supply_pool strategy `<T, ST, YT>` since every production
// Kai vault uses that strategy.
public fun kai_redeem<T, ST, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    vault: &mut kai_vault::Vault<T, YT>,
    strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_caller_authorized(access, pm, ctx);
    let (yt_balance, principal_portion) = pull_from_kai_lending<T, YT>(pm, yt_amount);
    let yt_burned = balance::value<YT>(&yt_balance);
    let mut ticket = kai_vault::withdraw<T, YT>(vault, yt_balance, clock);
    klsp::withdraw<T, ST, YT>(strategy, &mut ticket, supply_pool, clock);
    let underlying_balance = kai_vault::redeem_withdraw_ticket<T, YT>(vault, ticket);
    let redeemed_amount = balance::value<T>(&underlying_balance);
    let mut underlying_balance = underlying_balance;

    let (interest, fee_amount) = if (redeemed_amount > principal_portion) {
        let interest = redeemed_amount - principal_portion;
        let fee_amount = (((interest as u128) * (fee_house.fee_rate as u128)
            / FEE_DENOMINATOR) as u64);
        if (fee_amount > 0) {
            let fee_balance = balance::split<T>(&mut underlying_balance, fee_amount);
            deposit_into_fee_house<T>(fee_house, fee_balance);
        };
        (interest, fee_amount)
    } else {
        (0, 0)
    };

    add_to_balance<T>(pm, underlying_balance.into_coin(ctx));

    event::emit(KaiRedeemed {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        yt_type: type_name::with_defining_ids<YT>().into_string(),
        yt_burned,
        redeemed_amount,
        principal_portion,
        interest,
        fee_amount,
    });
}

// ============ Test-only accessors ============
// These functions exist solely so `tests/*` can drive and inspect internal state.
// They are stripped from non-test builds and do not enlarge the deployed bytecode.

#[test_only]
public fun test_only_pull_from_scallop_lending<T>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<MarketCoin<T>>, u64) {
    pull_from_scallop_lending<T>(pm, want_amount)
}

#[test_only]
public fun test_only_add_to_scallop_lending<T>(
    pm: &mut PositionManager,
    scoin: Balance<MarketCoin<T>>,
    principal_added: u64,
) {
    add_to_scallop_lending<T>(pm, scoin, principal_added)
}

#[test_only]
public fun test_only_add_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
) {
    add_to_balance<T>(pm, coin)
}

#[test_only]
public fun test_only_withdraw_from_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    withdraw_from_balance<T>(pm, amount, ctx)
}

#[test_only]
public fun test_only_add_to_fee<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
) {
    add_to_fee<T>(pm, coin)
}

#[test_only]
public fun test_only_withdraw_from_fee<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    withdraw_from_fee<T>(pm, amount, ctx)
}

#[test_only]
public fun test_only_take_fee<T>(
    balance_in: &mut Balance<T>,
    fee_house: &mut FeeHouse,
): u64 {
    take_fee<T>(balance_in, fee_house)
}

#[test_only]
public fun test_only_assert_caller_authorized(
    access: &AccessList,
    pm: &PositionManager,
    ctx: &TxContext,
) {
    assert_caller_authorized(access, pm, ctx)
}

#[test_only]
public fun test_only_lending_contains<T>(pm: &PositionManager): bool {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    bag::contains<String>(&pm.lending, coin_type)
}

#[test_only]
public fun test_only_scallop_lending_state<T>(pm: &PositionManager): (u64, u64) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    let v = bag::borrow<String, ScallopVault<T>>(&pm.lending, coin_type);
    (balance::value<MarketCoin<T>>(&v.scoin), v.principal)
}

#[test_only]
public fun test_only_balance_value<T>(pm: &PositionManager): u64 {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&pm.balance, coin_type)) {
        balance::value<T>(bag::borrow<String, Balance<T>>(&pm.balance, coin_type))
    } else { 0 }
}

#[test_only]
public fun test_only_fee_value<T>(pm: &PositionManager): u64 {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&pm.fee, coin_type)) {
        balance::value<T>(bag::borrow<String, Balance<T>>(&pm.fee, coin_type))
    } else { 0 }
}

#[test_only]
public fun test_only_fee_house_value<T>(fee_house: &FeeHouse): u64 {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&fee_house.fee, coin_type)) {
        balance::value<T>(bag::borrow<String, Balance<T>>(&fee_house.fee, coin_type))
    } else { 0 }
}

#[test_only]
public fun test_only_fee_house_rate(fee_house: &FeeHouse): u64 {
    fee_house.fee_rate
}

#[test_only]
public fun test_only_share_pm(pm: PositionManager) {
    transfer::share_object(pm);
}

#[test_only]
public fun test_only_insert_agent(pm: &mut PositionManager, agent: address) {
    vec_set::insert(&mut pm.agents, agent);
}

#[test_only]
public fun test_only_init(ctx: &mut TxContext) {
    init(ctx)
}

// Pure-math twin of the (P, S, w) split done by `pull_from_scallop_lending`.
// Lets `#[random_test]` exercise the principal-per-scoin monotonicity property
// without spinning up a PositionManager + Bag + Balance every iteration.

#[test_only]
public fun test_only_principal_portion(p: u64, s: u64, w: u64): u64 {
    (((p as u128) * (w as u128) / (s as u128)) as u64)
}

// ============ Prover-Only Accessors ============
// `#[spec_only]` items are visible only to `sui-prover` (asymptotic.tech).
// Regular `sui move build` ignores the attribute (the Move compiler tolerates
// unknown attributes as warnings) but the asymptotic toolchain strips them
// from production bytecode just like `#[test_only]`. They expose private
// fields so the spec package (`specs/`) can state postconditions. See SPEC.md.

#[spec_only]
public fun spec_fee_house_rate(fee_house: &FeeHouse): u64 {
    fee_house.fee_rate
}

#[spec_only]
public fun spec_max_fee_rate(): u64 {
    (MAX_FEE_RATE as u64)
}

// ---------------------------------------------------------------------------
// Spec-only state probes for finish_* `requires` clauses.
//
// These let the spec read the pre-call state of `pm.lending` / `pm.balance` /
// `fee_house.fee` so it can assume away balance::join overflow paths that the
// real cross-protocol PTB flow never reaches (skills/cdpm-calculation-skill/
// reference/cross-protocol-ptb.md: ticket.principal comes from clamped coin
// values, not arbitrary u64). Returns 0 when the bag entry is absent so the
// spec can unconditionally write `requires(probe + delta <= U64_MAX)`.
// ---------------------------------------------------------------------------

#[spec_only]
public fun spec_pm_scallop_vault_exists<T>(pm: &PositionManager): bool {
    let key = type_name::with_defining_ids<T>().into_string();
    bag::contains_with_type<String, ScallopVault<T>>(&pm.lending, key)
}

#[spec_only]
public fun spec_pm_kai_vault_exists<T, YT>(pm: &PositionManager): bool {
    let key = type_name::with_defining_ids<YT>().into_string();
    bag::contains_with_type<String, KaiVault<T, YT>>(&pm.lending, key)
}

#[spec_only]
public fun spec_pm_scallop_vault_principal<T>(pm: &PositionManager): u64 {
    let key = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, ScallopVault<T>>(&pm.lending, key)) {
        bag::borrow<String, ScallopVault<T>>(&pm.lending, key).principal
    } else { 0 }
}

#[spec_only]
public fun spec_pm_scallop_vault_scoin_value<T>(pm: &PositionManager): u64 {
    let key = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, ScallopVault<T>>(&pm.lending, key)) {
        balance::value<MarketCoin<T>>(&bag::borrow<String, ScallopVault<T>>(&pm.lending, key).scoin)
    } else { 0 }
}

#[spec_only]
public fun spec_pm_kai_vault_principal<T, YT>(pm: &PositionManager): u64 {
    let key = type_name::with_defining_ids<YT>().into_string();
    if (bag::contains_with_type<String, KaiVault<T, YT>>(&pm.lending, key)) {
        bag::borrow<String, KaiVault<T, YT>>(&pm.lending, key).principal
    } else { 0 }
}

#[spec_only]
public fun spec_pm_kai_vault_yt_value<T, YT>(pm: &PositionManager): u64 {
    let key = type_name::with_defining_ids<YT>().into_string();
    if (bag::contains_with_type<String, KaiVault<T, YT>>(&pm.lending, key)) {
        balance::value<YT>(&bag::borrow<String, KaiVault<T, YT>>(&pm.lending, key).yt_balance)
    } else { 0 }
}

#[spec_only]
public fun spec_pm_balance_value<T>(pm: &PositionManager): u64 {
    let key = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, Balance<T>>(&pm.balance, key)) {
        balance::value<T>(bag::borrow<String, Balance<T>>(&pm.balance, key))
    } else { 0 }
}

#[spec_only]
public fun spec_fee_house_balance_value<T>(fee_house: &FeeHouse): u64 {
    let key = type_name::with_defining_ids<T>().into_string();
    if (bag::contains_with_type<String, Balance<T>>(&fee_house.fee, key)) {
        balance::value<T>(bag::borrow<String, Balance<T>>(&fee_house.fee, key))
    } else { 0 }
}

// Bag size probes — `bag::add` increments `bag.size` (u64), so the prover
// needs `size < u64::MAX` to discharge the implicit overflow. Real bags are
// bounded by the number of distinct `coin_type` strings written across a
// PM's lifetime — far below u64::MAX in any conceivable deployment.

#[spec_only]
public fun spec_pm_lending_size(pm: &PositionManager): u64 {
    bag::length(&pm.lending)
}

#[spec_only]
public fun spec_pm_balance_size(pm: &PositionManager): u64 {
    bag::length(&pm.balance)
}

#[spec_only]
public fun spec_pm_fee_size(pm: &PositionManager): u64 {
    bag::length(&pm.fee)
}

#[spec_only]
public fun spec_fee_house_size(fee_house: &FeeHouse): u64 {
    bag::length(&fee_house.fee)
}

// Thin `#[spec_only] public fun` wrappers around the private lending helpers
// so the cross-module spec package can verify them. Each is a 1:1 forwarder;
// the prover proves properties of the wrapper, which transfer trivially to
// the wrapped private fn.

#[spec_only]
public fun spec_call_add_to_scallop_lending<T>(
    pm: &mut PositionManager,
    scoin: Balance<MarketCoin<T>>,
    principal_added: u64,
) {
    add_to_scallop_lending<T>(pm, scoin, principal_added)
}

#[spec_only]
public fun spec_call_pull_from_scallop_lending<T>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<MarketCoin<T>>, u64) {
    pull_from_scallop_lending<T>(pm, want_amount)
}

#[spec_only]
public fun spec_call_add_to_kai_lending<T, YT>(
    pm: &mut PositionManager,
    yt_balance: Balance<YT>,
    principal_added: u64,
) {
    add_to_kai_lending<T, YT>(pm, yt_balance, principal_added)
}

#[spec_only]
public fun spec_call_pull_from_kai_lending<T, YT>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<YT>, u64) {
    pull_from_kai_lending<T, YT>(pm, want_amount)
}

