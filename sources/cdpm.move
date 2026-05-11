module cdpm::cdpm;

use std::type_name;
use std::ascii::String;

use sui::event;
use sui::vec_set::{Self, VecSet};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::table::{Self, Table};
use sui::clock::Clock;

use cetusdlmm::pool::{Self, Pool};
use cetusdlmm::position::{Self, Position};
use cetusdlmm::versioned::Versioned;
use cetusdlmm::config::GlobalConfig;

use integer_mate::i32::I32;

use protocol::market::{Self, Market};
use protocol::reserve::{Self, MarketCoin};
use x::wit_table;

use kai_sav::vault as kai_vault;

const FEE_DENOMINATOR: u128 = 10000;
const MAX_FEE_RATE: u128 = 3000;

const ENotOwner: u64          = 1001;     // caller is not pm.owner
const ENotAllow: u64          = 1002;     // caller not in agents / access list (or invariant broken)
const EInvalidFeeRate: u64    = 1003;     // admin_set_fee given rate > MAX_FEE_RATE (30%)
const ELendingNotEmpty: u64   = 1004;     // user_close_pm called with non-empty lending Bag
const ENoSuchVault: u64       = 1005;     // pull_from_scallop_lending called for an absent (T, S) vault
const EReserveEmpty: u64      = 1006;     // Scallop reserve has zero supply or zero (cash+debt-revenue)
const EZeroExpected: u64      = 1007;     // start_* would yield 0 scoin/underlying (amount too small)
const EWrongPm: u64           = 1008;     // hot-potato ticket consumed against a different PM
const EAmountShortfall: u64   = 1009;     // finish_* received Coin with value < ticket.expected
const ENoSuchBalance: u64     = 1010;     // withdraw_from_balance/_fee called for an absent type

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
    lending: Bag,
}

public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>,
    principal: u64,
}

public struct ScallopSupplyTicket<phantom T> {
    pm_id: ID,
    expected_scoin: u64,
    principal: u64,
}

public struct ScallopRedeemTicket<phantom T> {
    pm_id: ID,
    expected_underlying: u64,
    scoin_burned: u64,
    principal_portion: u64,
}

// ============ Kai SAV vault holding ============
//
// Stored in the same `lending: Bag` as ScallopVault. Bag key uses YT's
// type_name so a single underlying T can simultaneously have a ScallopVault
// (key = T) and a KaiVault (key = YT) without collision. YT's TreasuryCap is
// owned by Kai's vault module, so external code cannot forge `Coin<YT>` —
// the type-pin defense matches Scallop's MarketCoin<T> guarantee.
public struct KaiVault<phantom T, phantom YT> has store {
    yt_balance: Balance<YT>,
    principal: u64,
}

public struct KaiSupplyTicket<phantom T, phantom YT> {
    pm_id: ID,
    expected_yt: u64,
    principal: u64,
}

public struct KaiRedeemTicket<phantom T, phantom YT> {
    pm_id: ID,
    expected_underlying: u64,
    yt_burned: u64,
    principal_portion: u64,
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

public struct ScallopMarketCoinExtracted has copy, drop {
    pm_id: ID,
    coin_type: String,
    market_coin_amount: u64,
    principal_removed: u64,
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

public struct KaiYTExtracted has copy, drop {
    pm_id: ID,
    coin_type: String,
    yt_type: String,
    yt_amount: u64,
    principal_removed: u64,
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
        lending: bag::new(ctx),
    };
    let pm_id = object::id(&pm);
    table::add(&mut record.record, pm_id, true);
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

    let PositionManager { id, owner, agents: _, position, balance, fee, lending } = pm;

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
    assert!(bag::is_empty(&lending), ELendingNotEmpty);
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
    if (coin.value() == 0) { coin.destroy_zero(); return };
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
    if (amount == 0) return coin::zero<T>(ctx);
    let coin_type = type_name::with_defining_ids<T>().into_string();
    assert!(bag::contains<String>(&pm.balance, coin_type), ENoSuchBalance);
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
    if (amount == 0) return coin::zero<T>(ctx);
    let coin_type = type_name::with_defining_ids<T>().into_string();
    assert!(bag::contains<String>(&pm.fee, coin_type), ENoSuchBalance);
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
    deposit_into_fee_house<T>(fee_house, fee);
}

fun deposit_into_fee_house<T>(
    fee_house: &mut FeeHouse,
    fee: Balance<T>,
) {
    let coin_type = type_name::with_defining_ids<T>().into_string();
    if (bag::contains<String>(&fee_house.fee, coin_type)) {
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
    if (bag::contains<String>(&pm.lending, coin_type)) {
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
    assert!(bag::contains<String>(&pm.lending, coin_type), ENoSuchVault);
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

fun compute_expected_scoin<T>(market: &Market, coin_amount: u64): u64 {
    let reserve = market::vault(market);
    let sheets = reserve::balance_sheets(reserve);
    let key = type_name::with_defining_ids<T>();
    let sheet = wit_table::borrow(sheets, key);
    let (cash, debt, revenue, supply) = reserve::balance_sheet(sheet);
    if (supply == 0) {
        coin_amount
    } else {
        // Cast u64 → u128 BEFORE arithmetic so cash+debt cannot overflow u64.
        // u128 holds the full u64×u64 product; sui::balance values are u64 (balance.move:36).
        let cash_u = cash as u128;
        let debt_u = debt as u128;
        let revenue_u = revenue as u128;
        assert!(cash_u + debt_u >= revenue_u, EReserveEmpty);
        let denom = cash_u + debt_u - revenue_u;
        assert!(denom > 0, EReserveEmpty);
        (((coin_amount as u128) * (supply as u128) / denom) as u64)
    }
}

fun compute_expected_underlying_scallop<T>(market: &Market, scoin_amount: u64): u64 {
    let reserve = market::vault(market);
    let sheets = reserve::balance_sheets(reserve);
    let key = type_name::with_defining_ids<T>();
    let sheet = wit_table::borrow(sheets, key);
    let (cash, debt, revenue, supply) = reserve::balance_sheet(sheet);
    assert!(supply > 0, EReserveEmpty);
    let cash_u = cash as u128;
    let debt_u = debt as u128;
    let revenue_u = revenue as u128;
    assert!(cash_u + debt_u >= revenue_u, EReserveEmpty);
    let numer_extra = cash_u + debt_u - revenue_u;
    // u128 is sufficient. Scallop enforces (cash + debt - revenue) ≤ u64::MAX
    // via u64 arithmetic in reserve.move (`accrue_interest`, `into_underlying_coin_amount`),
    // so numer_extra ≤ 2^64 - 1 and the product scoin_amount * numer_extra ≤ (2^64 - 1)^2 < 2^128.
    (((scoin_amount as u128) * numer_extra / (supply as u128)) as u64)
}

// ============ Scallop Lending Public API (Hot Potato) ============

public fun scallop_start_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, ScallopSupplyTicket<T>) {
    assert_caller_authorized(access, pm, ctx);
    let coin: Coin<T> = withdraw_from_balance<T>(pm, amount, ctx);
    let actual = coin.value();
    let expected_scoin = compute_expected_scoin<T>(market, actual);
    assert!(expected_scoin > 0, EZeroExpected);
    let ticket = ScallopSupplyTicket<T> {
        pm_id: object::id(pm),
        expected_scoin,
        principal: actual,
    };
    (coin, ticket)
}

public fun scallop_finish_supply<T>(
    pm: &mut PositionManager,
    ticket: ScallopSupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
) {
    let ScallopSupplyTicket { pm_id, expected_scoin, principal } = ticket;
    assert!(pm_id == object::id(pm), EWrongPm);
    let scoin_amount = scoin.value();
    assert!(scoin_amount >= expected_scoin, EAmountShortfall);
    add_to_scallop_lending<T>(pm, scoin.into_balance(), principal);

    event::emit(ScallopSupplied {
        pm_id,
        coin_type: type_name::with_defining_ids<T>().into_string(),
        deposit_amount: principal,
        market_coin_minted: scoin_amount,
    });
}

public fun scallop_start_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    market_coin_amount: u64,
    ctx: &mut TxContext,
): (Coin<MarketCoin<T>>, ScallopRedeemTicket<T>) {
    assert_caller_authorized(access, pm, ctx);
    let (s_balance, principal_portion) = pull_from_scallop_lending<T>(pm, market_coin_amount);
    let scoin_burned = balance::value<MarketCoin<T>>(&s_balance);
    let expected_underlying = compute_expected_underlying_scallop<T>(market, scoin_burned);
    assert!(expected_underlying > 0, EZeroExpected);
    let ticket = ScallopRedeemTicket<T> {
        pm_id: object::id(pm),
        expected_underlying,
        scoin_burned,
        principal_portion,
    };
    (s_balance.into_coin(ctx), ticket)
}

public fun scallop_finish_redeem<T>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: ScallopRedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    let ScallopRedeemTicket { pm_id, expected_underlying, scoin_burned, principal_portion } = ticket;
    assert!(pm_id == object::id(pm), EWrongPm);
    let redeemed_amount = underlying.value();
    assert!(redeemed_amount >= expected_underlying, EAmountShortfall);
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
        pm_id,
        coin_type: type_name::with_defining_ids<T>().into_string(),
        market_coin_redeemed: scoin_burned,
        redeemed_amount,
        principal_portion,
        interest,
        fee_amount,
    });
}

public fun user_extract_scallop_market_coin<T>(
    pm: &mut PositionManager,
    market_coin_amount: u64,
    ctx: &mut TxContext,
): Coin<MarketCoin<T>> {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let (s_balance, principal_portion) = pull_from_scallop_lending<T>(pm, market_coin_amount);
    let s_amount = balance::value<MarketCoin<T>>(&s_balance);

    event::emit(ScallopMarketCoinExtracted {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        market_coin_amount: s_amount,
        principal_removed: principal_portion,
    });

    s_balance.into_coin(ctx)
}

// ============ Kai SAV Lending — Hot-Potato + YT type-pin ============

fun add_to_kai_lending<T, YT>(
    pm: &mut PositionManager,
    yt_balance: Balance<YT>,
    principal_added: u64,
) {
    let key = type_name::with_defining_ids<YT>().into_string();
    if (bag::contains<String>(&pm.lending, key)) {
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
    assert!(bag::contains<String>(&pm.lending, key), ENoSuchVault);
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

fun compute_expected_yt<T, YT>(
    vault: &kai_vault::Vault<T, YT>,
    clock: &Clock,
    t_amount: u64,
): u64 {
    let total = kai_vault::total_available_balance<T, YT>(vault, clock);
    let yt_supply = kai_vault::total_yt_supply<T, YT>(vault);
    if (total == 0) {
        // bootstrap (vault.move:606-608): 1:1 when total_available == 0.
        // NOTE: yt_supply == 0 with total > 0 is a degenerate state we cannot
        // safely match (Kai's deposit auto-mints performance fees, see plan
        // §"Security audit report" point 1). In practice total > 0 implies yt_supply > 0
        // for all non-bootstrap vaults; if yt_supply == 0 here we return 0
        // and scallop_start_supply aborts via EZeroExpected.
        t_amount
    } else {
        (((yt_supply as u128) * (t_amount as u128) / (total as u128)) as u64)
    }
}

fun compute_expected_underlying_kai<T, YT>(
    vault: &kai_vault::Vault<T, YT>,
    clock: &Clock,
    yt_amount: u64,
): u64 {
    let total = kai_vault::total_available_balance<T, YT>(vault, clock);
    let yt_supply = kai_vault::total_yt_supply<T, YT>(vault);
    assert!(yt_supply > 0, EReserveEmpty);
    (((yt_amount as u128) * (total as u128) / (yt_supply as u128)) as u64)
}

public fun kai_start_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<T>, KaiSupplyTicket<T, YT>) {
    assert_caller_authorized(access, pm, ctx);
    let coin: Coin<T> = withdraw_from_balance<T>(pm, amount, ctx);
    let actual = coin.value();
    let expected_yt = compute_expected_yt<T, YT>(vault, clock, actual);
    assert!(expected_yt > 0, EZeroExpected);
    let ticket = KaiSupplyTicket<T, YT> {
        pm_id: object::id(pm),
        expected_yt,
        principal: actual,
    };
    (coin, ticket)
}

public fun kai_finish_supply<T, YT>(
    pm: &mut PositionManager,
    ticket: KaiSupplyTicket<T, YT>,
    yt: Coin<YT>,
) {
    let KaiSupplyTicket { pm_id, expected_yt, principal } = ticket;
    assert!(pm_id == object::id(pm), EWrongPm);
    let yt_amount = yt.value();
    assert!(yt_amount >= expected_yt, EAmountShortfall);
    add_to_kai_lending<T, YT>(pm, yt.into_balance(), principal);

    event::emit(KaiSupplied {
        pm_id,
        coin_type: type_name::with_defining_ids<T>().into_string(),
        yt_type: type_name::with_defining_ids<YT>().into_string(),
        deposit_amount: principal,
        yt_minted: yt_amount,
    });
}

public fun kai_start_redeem<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<YT>, KaiRedeemTicket<T, YT>) {
    assert_caller_authorized(access, pm, ctx);
    let (yt_balance, principal_portion) = pull_from_kai_lending<T, YT>(pm, yt_amount);
    let yt_burned = balance::value<YT>(&yt_balance);
    let expected_underlying = compute_expected_underlying_kai<T, YT>(vault, clock, yt_burned);
    assert!(expected_underlying > 0, EZeroExpected);
    let ticket = KaiRedeemTicket<T, YT> {
        pm_id: object::id(pm),
        expected_underlying,
        yt_burned,
        principal_portion,
    };
    (yt_balance.into_coin(ctx), ticket)
}

public fun kai_finish_redeem<T, YT>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: KaiRedeemTicket<T, YT>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    let KaiRedeemTicket { pm_id, expected_underlying, yt_burned, principal_portion } = ticket;
    assert!(pm_id == object::id(pm), EWrongPm);
    let redeemed_amount = underlying.value();
    assert!(redeemed_amount >= expected_underlying, EAmountShortfall);
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

    event::emit(KaiRedeemed {
        pm_id,
        coin_type: type_name::with_defining_ids<T>().into_string(),
        yt_type: type_name::with_defining_ids<YT>().into_string(),
        yt_burned,
        redeemed_amount,
        principal_portion,
        interest,
        fee_amount,
    });
}

public fun user_extract_kai_yt<T, YT>(
    pm: &mut PositionManager,
    yt_amount: u64,
    ctx: &mut TxContext,
): Coin<YT> {
    assert!(pm.owner == ctx.sender(), ENotOwner);
    let (yt_balance, principal_portion) = pull_from_kai_lending<T, YT>(pm, yt_amount);
    let amount = balance::value<YT>(&yt_balance);

    event::emit(KaiYTExtracted {
        pm_id: object::id(pm),
        coin_type: type_name::with_defining_ids<T>().into_string(),
        yt_type: type_name::with_defining_ids<YT>().into_string(),
        yt_amount: amount,
        principal_removed: principal_portion,
    });

    yt_balance.into_coin(ctx)
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
) {
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
public fun test_only_scallop_supply_ticket_fields<T>(
    ticket: &ScallopSupplyTicket<T>,
): (ID, u64, u64) {
    (ticket.pm_id, ticket.expected_scoin, ticket.principal)
}

#[test_only]
public fun test_only_scallop_redeem_ticket_fields<T>(
    ticket: &ScallopRedeemTicket<T>,
): (ID, u64, u64, u64) {
    (
        ticket.pm_id,
        ticket.expected_underlying,
        ticket.scoin_burned,
        ticket.principal_portion,
    )
}

#[test_only]
public fun test_only_make_pm(owner: address, ctx: &mut TxContext): PositionManager {
    PositionManager {
        id: object::new(ctx),
        owner,
        agents: vec_set::empty(),
        position: option::none(),
        balance: bag::new(ctx),
        fee: bag::new(ctx),
        lending: bag::new(ctx),
    }
}

#[test_only]
public fun test_only_share_pm(pm: PositionManager) {
    transfer::share_object(pm);
}

#[test_only]
public fun test_only_destroy_empty_pm(pm: PositionManager) {
    let PositionManager { id, owner: _, agents: _, position, balance, fee, lending } = pm;
    option::destroy_none(position);
    bag::destroy_empty(balance);
    bag::destroy_empty(fee);
    bag::destroy_empty(lending);
    id.delete();
}

#[test_only]
public fun test_only_insert_agent(pm: &mut PositionManager, agent: address) {
    vec_set::insert(&mut pm.agents, agent);
}

#[test_only]
public fun test_only_init(ctx: &mut TxContext) {
    init(ctx)
}

// Pure-math twins of the (P, S, w) split done by `pull_from_scallop_lending`. These let
// `#[random_test]` exercise the principal-per-scoin monotonicity property
// without spinning up a PositionManager + Bag + Balance every iteration.

#[test_only]
public fun test_only_principal_portion(p: u64, s: u64, w: u64): u64 {
    (((p as u128) * (w as u128) / (s as u128)) as u64)
}

#[test_only]
public fun test_only_compute_expected_scoin_pure(
    cash: u64, debt: u64, revenue: u64, supply: u64, coin_amount: u64,
): u64 {
    if (supply == 0) {
        coin_amount
    } else {
        let cash_u = cash as u128;
        let debt_u = debt as u128;
        let revenue_u = revenue as u128;
        assert!(cash_u + debt_u >= revenue_u, EReserveEmpty);
        let denom = cash_u + debt_u - revenue_u;
        assert!(denom > 0, EReserveEmpty);
        (((coin_amount as u128) * (supply as u128) / denom) as u64)
    }
}

#[test_only]
public fun test_only_compute_expected_underlying_pure(
    cash: u64, debt: u64, revenue: u64, supply: u64, scoin_amount: u64,
): u64 {
    assert!(supply > 0, EReserveEmpty);
    let cash_u = cash as u128;
    let debt_u = debt as u128;
    let revenue_u = revenue as u128;
    assert!(cash_u + debt_u >= revenue_u, EReserveEmpty);
    let numer_extra = cash_u + debt_u - revenue_u;
    (((scoin_amount as u128) * numer_extra / (supply as u128)) as u64)
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
public fun spec_scallop_supply_ticket_pm_id<T>(ticket: &ScallopSupplyTicket<T>): ID {
    ticket.pm_id
}

#[spec_only]
public fun spec_scallop_supply_ticket_expected_scoin<T>(ticket: &ScallopSupplyTicket<T>): u64 {
    ticket.expected_scoin
}

#[spec_only]
public fun spec_scallop_redeem_ticket_pm_id<T>(ticket: &ScallopRedeemTicket<T>): ID {
    ticket.pm_id
}

#[spec_only]
public fun spec_scallop_redeem_ticket_expected_underlying<T>(ticket: &ScallopRedeemTicket<T>): u64 {
    ticket.expected_underlying
}

#[spec_only]
public fun spec_kai_supply_ticket_pm_id<T, YT>(ticket: &KaiSupplyTicket<T, YT>): ID {
    ticket.pm_id
}

#[spec_only]
public fun spec_kai_supply_ticket_expected_yt<T, YT>(ticket: &KaiSupplyTicket<T, YT>): u64 {
    ticket.expected_yt
}

#[spec_only]
public fun spec_kai_redeem_ticket_pm_id<T, YT>(ticket: &KaiRedeemTicket<T, YT>): ID {
    ticket.pm_id
}

#[spec_only]
public fun spec_kai_redeem_ticket_expected_underlying<T, YT>(ticket: &KaiRedeemTicket<T, YT>): u64 {
    ticket.expected_underlying
}
