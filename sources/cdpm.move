module cdpm::cdpm;

use std::type_name;
use std::ascii::{Self, String};

use sui::vec_set::{Self, VecSet};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::table::{Self, Table};
use sui::clock::Clock;

use cetusdlmm::pool::{Self, Pool};
use cetusdlmm::position::{Position};
use cetusdlmm::reward::RewardManager;
use cetusdlmm::versioned::Versioned;
use cetusdlmm::config::GlobalConfig;

const FEE_DENOMINATOR: u128 = 10000;

const ENotOwner: u64 =  1001;
const ENotAllow: u64 =  1002;

// ============ Data Structures ============
public struct AccessList has key {
    id: UID,
    allow: VecSet<address>,
}

public struct AdminCap has key {
    id: UID,
}

#[allow(unused_field)]
public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,
    fee: Bag,
}

#[allow(unused_field)]
public struct PositionManager has key {
    id: UID,
    owner: address,
    agents: VecSet<address>,
    position: Option<Position>,
    balance: Bag,
    fee: Bag,
}

public struct GlobalRecord has key {
    id: UID,
    record: Table<address, ID>,
}

public struct Record has key {
    id: UID,
    record: Table<ID, bool>,
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
}

public fun register_and_return_record(
    global_record: &mut GlobalRecord,
    ctx: &mut TxContext,
): Record {
    let record = Record {
        id: object::new(ctx),
        record: table::new<ID, bool>(ctx),
    };
    table::add(&mut global_record.record, ctx.sender(), object::id(&record));
    record
}

public fun share_record(
    record: Record
) {
    transfer::share_object(record);
}

public fun user_deposit<CoinTypeA, CoinTypeB>(
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
    let pm = PositionManager {
        id: object::new(ctx),
        owner: ctx.sender(),
        agents: vec_set::empty(),
        position: option::some(position),
        balance: bag::new(ctx),
        fee: bag::new(ctx),
    };
    table::add(&mut record.record, object::id(&pm), true);
    transfer::share_object(pm);
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
    add_liquidity_private(
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
}

public fun user_add_liquidity_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
    ctx: &TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    add_to_balance(pm, coin);
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
    let (balance_a, balance_b) = pool::remove_liquidity(
        pool,
        option::borrow_mut(&mut pm.position),
        bins,
        liquidity_shares,
        config,
        versioned,
        clk,
        ctx,
    );
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
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
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
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    balance_reward.into_coin(ctx)
}

public fun user_remove_liquidity_from_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    withdraw_from_balance(pm, amount, ctx)
}

public fun user_withdraw_fee<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    withdraw_from_fee(pm, amount, ctx)
}

public fun user_insert_agent(
    pm: &mut PositionManager,
    agent: address,
    ctx: &TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    vec_set::insert(&mut pm.agents, agent);
}

public fun user_remove_agent(
    pm: &mut PositionManager,
    agent: address,
    ctx: &TxContext,
) {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    vec_set::remove(&mut pm.agents, &agent);
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
    table::remove<ID, bool>(&mut record.record, object::id(&pm));

    let PositionManager { id, owner: _, agents: _, position, balance, fee } = pm;

    if (option::is_some<Position>(&position)) {
        let p = option::destroy_some<Position>(position);
        let (cert, balance_a, balance_b) = pool::close_position<CoinTypeA, CoinTypeB>(
            pool,
            p,
            config,
            versioned,
            clk,
            ctx,
        );
        pool::destroy_close_position_cert(cert, versioned);
        transfer::public_transfer(balance_a.into_coin(ctx), ctx.sender());
        transfer::public_transfer(balance_b.into_coin(ctx), ctx.sender());
    } else {
        option::destroy_none<Position>(position);
    };
    bag::destroy_empty(balance);
    bag::destroy_empty(fee);
    object::delete(id);
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
    add_liquidity_private(
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
    let (balance_a, balance_b) = pool::remove_liquidity(
        pool,
        option::borrow_mut(&mut pm.position),
        bins,
        liquidity_shares,
        config,
        versioned,
        clk,
        ctx,
    );
    add_to_balance<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_balance<CoinTypeB>(pm, balance_b.into_coin(ctx));
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
    let (mut balance_a, mut balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    take_fee<CoinTypeA>(&mut balance_a, fee_house);
    take_fee<CoinTypeB>(&mut balance_b, fee_house);
    add_to_fee<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_fee<CoinTypeB>(pm, balance_b.into_coin(ctx));
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
    let mut balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    take_fee<RewardType>(&mut balance_reward, fee_house);
    add_to_fee<RewardType>(pm, balance_reward.into_coin(ctx));
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
    add_to_balance<T>(pm, fee);
}

// ============ Emergency Functions ============
public fun protocol_close_position_emergency<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    let p = option::extract<Position>(&mut pm.position);
    let (cert, balance_a, balance_b) = pool::close_position<CoinTypeA, CoinTypeB>(
        pool,
        p,
        config,
        versioned,
        clk,
        ctx,
    );
    pool::destroy_close_position_cert(cert, versioned);
    add_to_balance<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_balance<CoinTypeB>(pm, balance_b.into_coin(ctx));
}

public fun protocol_collect_fee_emergency<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    add_to_fee<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_fee<CoinTypeB>(pm, balance_b.into_coin(ctx));
}

public fun protocol_collect_reward_emergency<CoinTypeA, CoinTypeB, RewardType>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&access.allow, &ctx.sender()), ENotAllow);
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    add_to_fee<RewardType>(pm, balance_reward.into_coin(ctx));
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
    add_liquidity_private(
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
    let (balance_a, balance_b) = pool::remove_liquidity(
        pool,
        option::borrow_mut(&mut pm.position),
        bins,
        liquidity_shares,
        config,
        versioned,
        clk,
        ctx,
    );
    add_to_balance<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_balance<CoinTypeB>(pm, balance_b.into_coin(ctx));
}

public fun agent_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    add_to_fee<CoinTypeA>(pm, balance_a.into_coin(ctx));
    add_to_fee<CoinTypeB>(pm, balance_b.into_coin(ctx));
}

public fun agent_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    assert!(vec_set::contains<address>(&pm.agents, &ctx.sender()), ENotAllow);
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    add_to_fee<RewardType>(pm, balance_reward.into_coin(ctx));
}

// ============ Admin Functions ============
public fun admin_transfer(
    admin_cap: AdminCap,
    to: address,
) {
    transfer::transfer(admin_cap, to);
}

public fun admin_set_fee(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    fee_rate: u64,
) {
    fee_house.fee_rate = fee_rate;
}

public fun admin_collect_fee<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
): Coin<T> {
    bag::remove<String, Coin<T>>(&mut fee_house.fee, type_name::with_defining_ids<T>().into_string())
}

public fun admin_insert_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
) {
    vec_set::insert(&mut access.allow, bot);
}

public fun admin_remove_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
) {
    vec_set::remove(&mut access.allow, &bot);
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
) {
    let add_liquidity_cert = pool::add_liquidity(
        pool,
        option::borrow_mut(&mut pm.position),
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
        option::borrow_mut(&mut pm.position),
        add_liquidity_cert,
        balance_a,
        balance_b,
        versioned,
    );
}

fun add_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&pm.balance, coin_type)) {
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
    let coin_type = type_name::with_defining_ids<T>().into_string();
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
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&pm.fee, coin_type)) {
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
    let coin_type = type_name::with_defining_ids<T>().into_string();
    let balance_bm = bag::borrow_mut<String, Balance<T>>(&mut pm.fee, coin_type);
    let balance_amount = balance::value<T>(balance_bm);
    if (amount >= balance_amount) {
        bag::remove<String, Balance<T>>(&mut pm.fee, coin_type).into_coin(ctx)
    } else {
        balance::split<T>(bag::borrow_mut(&mut pm.fee, coin_type), amount).into_coin(ctx)
    }
}

fun take_fee<T>(
    balance_in: &mut Balance<T>,
    fee_house: &mut FeeHouse,
) {
    let amount_in = balance::value<T>(balance_in);
    let fee_amount = (((amount_in as u128) * (fee_house.fee_rate as u128) / FEE_DENOMINATOR) as u64);
    let fee = balance::split<T>(balance_in, fee_amount);
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&fee_house.fee, coin_type)) {
        balance::join<T>(bag::borrow_mut(&mut fee_house.fee, coin_type), fee);
    } else {
        bag::add<String, Balance<T>>(&mut fee_house.fee, coin_type, fee);
    };
}