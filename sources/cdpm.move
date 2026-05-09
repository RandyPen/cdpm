module cdpm::cdpm;

use std::type_name;
use std::ascii::String;

use sui::event;
use sui::vec_set::{Self, VecSet};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::table::{Self, Table};
use sui::clock::Clock;

use cetusdlmm::pool::{Self, Pool};
use cetusdlmm::position::{Self, Position};
use cetusdlmm::versioned::Versioned;
use cetusdlmm::config::GlobalConfig;

use integer_mate::i32::I32;

const FEE_DENOMINATOR: u128 = 10000;

const ENotOwner: u64        = 1001;
const ENotAllow: u64        = 1002;
const EInvalidFeeRate: u64  = 1003;

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
    record: VecSet<ID>,
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

public struct PositionExtract has copy, drop {
    pm_id: ID,
    owner: address,
}

public struct PositionManagerClosed has copy, drop {
    pm_id: ID,
    owner: address,
}

public struct LiquidityAdded has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    amount_a: u64,
    amount_b: u64,
    by: address,
}

public struct LiquidityRemoved has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    by: address,
}

public struct FeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,
    coin_type_b: String,
    amount_a: u64,
    amount_b: u64,
    by: address,
}

public struct RewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,
    amount: u64,
    by: address,
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
    by: address,
}

public struct ProtocolLiquidityRemoved has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    by: address,
}

public struct AgentLiquidityAdded has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    amount_a: u64,
    amount_b: u64,
    by: address,
}

public struct AgentLiquidityRemoved has copy, drop {
    pm_id: ID,
    pool_id: ID,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    by: address,
}

public struct AgentFeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,
    coin_type_b: String,
    amount_a: u64,
    amount_b: u64,
    by: address,
}

public struct AgentRewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,
    amount: u64,
    by: address,
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
        record: vec_set::empty<ID>(),
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
    assert!(vec_set::is_empty(&record), ENotAllow);
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
    let lower_bin_id = position::lower_bin_id(&position);
    let upper_bin_id = position::upper_bin_id(&position);
    let liquidity_shares = position::liquidity_shares(&position);
    let pm = PositionManager {
        id: object::new(ctx),
        owner: ctx.sender(),
        agents: vec_set::empty(),
        position: option::some(position),
        balance: bag::new(ctx),
        fee: bag::new(ctx),
    };
    let pm_id = object::id(&pm);
    vec_set::insert(&mut record.record, pm_id);
    transfer::share_object(pm);
    
    event::emit(PositionManagerCreated {
        pm_id,
        owner: ctx.sender(),
        pool_id: object::id(pool),
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
        position: option::some(position),
        balance: bag::new(ctx),
        fee: bag::new(ctx),
    };
    let pm_id = object::id(&pm);
    vec_set::insert(&mut record.record, pm_id);
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

// in case of Cetus DLMM package upgrade
public fun user_get_and_return_position(
    pm: &mut PositionManager,
    ctx: &TxContext,
): Position {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    event::emit(PositionExtract {
        pm_id: object::id(pm),
        owner: ctx.sender(),
    });

    option::extract(&mut pm.position)
}

#[allow(lint(self_transfer))]
public fun user_get_position(
    pm: &mut PositionManager,
    ctx: &TxContext,
) {
    let position = user_get_and_return_position(pm, ctx);
    transfer::public_transfer(position, ctx.sender());
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
        by: ctx.sender(),
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
    
    event::emit(LiquidityRemoved {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins,
        liquidity_shares,
        by: ctx.sender(),
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
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
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
        by: ctx.sender(),
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
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
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
        by: ctx.sender(),
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
    vec_set::remove(&mut record.record, &pm_id);

    let PositionManager { id, owner, agents: _, position, balance, fee } = pm;

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
    balance.destroy_empty();
    fee.destroy_empty();
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
        by: ctx.sender(),
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

    event::emit(ProtocolLiquidityRemoved {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins,
        liquidity_shares,
        by: ctx.sender(),
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
    let (mut balance_a, mut balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    let amount_a_before = balance_a.value();
    let amount_b_before = balance_b.value();
    take_fee<CoinTypeA>(&mut balance_a, fee_house);
    take_fee<CoinTypeB>(&mut balance_b, fee_house);
    let amount_a = balance_a.value();
    let amount_b = balance_b.value();
    let fee_a = amount_a_before - amount_a;
    let fee_b = amount_b_before - amount_b;
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
    let mut balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
        config,
        versioned,
        ctx,
    );
    let amount_before = balance_reward.value();
    take_fee<RewardType>(&mut balance_reward, fee_house);
    let amount = balance_reward.value();
    let fee_amount = amount_before - amount;
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
        by: ctx.sender(),
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

    event::emit(AgentLiquidityRemoved {
        pm_id: object::id(pm),
        pool_id: object::id(pool),
        bins,
        liquidity_shares,
        by: ctx.sender(),
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
    let (balance_a, balance_b) = pool::collect_position_fee<CoinTypeA, CoinTypeB>(
        pool,
        option::borrow_mut(&mut pm.position),
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
        by: ctx.sender(),
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
    let balance_reward = pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>(
        pool,
        option::borrow_mut(&mut pm.position),
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
        by: ctx.sender(),
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
    assert!((fee_rate as u128) <= FEE_DENOMINATOR, EInvalidFeeRate);
    let old_fee_rate = fee_house.fee_rate;
    fee_house.fee_rate = fee_rate;

    event::emit(FeeRateUpdated {
        fee_house_id: object::id(fee_house),
        old_fee_rate,
        new_fee_rate: fee_rate,
    });
}

public fun admin_new_fee_house(
    _: &AdminCap,
    fee_rate: u64,
    ctx: &mut TxContext,
) {
    assert!((fee_rate as u128) <= FEE_DENOMINATOR, EInvalidFeeRate);
    let fee_house = FeeHouse {
        id: object::new(ctx),
        fee_rate: fee_rate,
        fee: bag::new(ctx),
    };
    transfer::share_object(fee_house);
}

public fun admin_collect_fee_return_coin<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    ctx: &mut TxContext,
): Coin<T> {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    let coin: Coin<T> = bag::remove<String, Coin<T>>(&mut fee_house.fee, coin_type);
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
    let coin: Coin<T> = bag::remove<String, Coin<T>>(&mut fee_house.fee, coin_type);
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
    (amount_a, amount_b)
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
