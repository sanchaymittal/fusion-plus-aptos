/// Fee management system for resolver fees and access control
/// Implements credit-based fee payment and resolver whitelisting
module crosschain_escrow_factory::fee_bank {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::timestamp;

    /// Error codes
    const E_INSUFFICIENT_CREDIT: u64 = 1;
    const E_INVALID_RESOLVER: u64 = 2;
    const E_UNAUTHORIZED: u64 = 3;
    const E_INVALID_WHITELIST: u64 = 4;
    const E_RESOLVER_NOT_ALLOWED: u64 = 5;
    const E_INVALID_FEE: u64 = 6;
    const E_ZERO_AMOUNT: u64 = 7;
    const E_ALREADY_INITIALIZED: u64 = 8;

    /// Constants
    const ORDER_FEE_BASE_POINTS: u256 = 1_000_000_000_000_000; // 1e15

    /// Represents a whitelisted resolver with time-based access
    struct WhitelistedResolver has copy, drop, store {
        resolver_address_masked: u128, // Last 10 bytes of address (80 bits)
        time_delta: u16,               // Time delta from previous resolver
    }

    /// Fee bank for managing resolver credits
    struct FeeBank<phantom FeeTokenType> has key {
        owner: address,
        credits: vector<CreditEntry>,  // User credit balances
        total_deposited: u64,         // Total amount deposited
        total_fees_collected: u64,    // Total fees collected
        
        // Events
        deposit_events: EventHandle<DepositEvent>,
        withdrawal_events: EventHandle<WithdrawalEvent>,
        fee_charge_events: EventHandle<FeeChargeEvent>,
    }

    /// Credit entry for a user
    struct CreditEntry has store {
        user: address,
        available_credit: u64,
        total_deposited: u64,
        total_fees_paid: u64,
    }

    /// Access token configuration for resolver validation
    struct AccessTokenConfig<phantom AccessTokenType> has key {
        min_balance_required: u64,
    }

    /// Resolver whitelist configuration
    struct ResolverWhitelist has copy, drop, store {
        allowed_time: u64,           // Base time when interaction is allowed
        resolvers: vector<WhitelistedResolver>, // List of whitelisted resolvers
    }

    /// Fee configuration for orders
    struct FeeConfig has copy, drop, store {
        resolver_fee_enabled: bool,
        base_resolver_fee: u64,      // Base fee in fee token units
        fee_rate: u64,               // Fee rate in basis points
    }

    // Events
    struct DepositEvent has drop, store {
        user: address,
        amount: u64,
        total_credit: u64,
        timestamp: u64,
    }

    struct WithdrawalEvent has drop, store {
        user: address,
        amount: u64,
        remaining_credit: u64,
        timestamp: u64,
    }

    struct FeeChargeEvent has drop, store {
        resolver: address,
        fee_amount: u64,
        remaining_credit: u64,
        timestamp: u64,
    }

    /// Initializes the fee bank for a specific token type
    public entry fun initialize_fee_bank<FeeTokenType>(
        owner: &signer
    ) {
        let owner_addr = signer::address_of(owner);
        assert!(!exists<FeeBank<FeeTokenType>>(owner_addr), error::already_exists(E_ALREADY_INITIALIZED));
        
        move_to(owner, FeeBank<FeeTokenType> {
            owner: owner_addr,
            credits: vector::empty(),
            total_deposited: 0,
            total_fees_collected: 0,
            deposit_events: account::new_event_handle(owner),
            withdrawal_events: account::new_event_handle(owner),
            fee_charge_events: account::new_event_handle(owner),
        });
    }

    /// Initializes access token configuration
    public entry fun initialize_access_token<AccessTokenType>(
        admin: &signer,
        min_balance_required: u64
    ) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<AccessTokenConfig<AccessTokenType>>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));
        
        move_to(admin, AccessTokenConfig<AccessTokenType> {
            min_balance_required,
        });
    }

    /// Deposits fee tokens to get credits
    public fun deposit<FeeTokenType>(
        user: &signer,
        fee_bank_owner: address,
        tokens: Coin<FeeTokenType>
    ): Coin<FeeTokenType> acquires FeeBank {
        let user_addr = signer::address_of(user);
        let amount = coin::value(&tokens);
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // TODO: Actually deposit tokens into fee bank - for now just return them
        // In a real implementation, this would transfer to the fee bank's account
        
        let fee_bank = borrow_global_mut<FeeBank<FeeTokenType>>(fee_bank_owner);
        
        // Find or create user credit entry
        let credit_entry = find_or_create_credit_entry(&mut fee_bank.credits, user_addr);
        credit_entry.available_credit = credit_entry.available_credit + amount;
        credit_entry.total_deposited = credit_entry.total_deposited + amount;
        
        fee_bank.total_deposited = fee_bank.total_deposited + amount;
        
        // Emit deposit event
        event::emit_event(&mut fee_bank.deposit_events, DepositEvent {
            user: user_addr,
            amount,
            total_credit: credit_entry.available_credit,
            timestamp: timestamp::now_seconds(),
        });
        
        tokens
    }

    /// Withdraws credits back to fee tokens
    public fun withdraw<FeeTokenType>(
        user: &signer,
        fee_bank_owner: address,
        amount: u64
    ): Coin<FeeTokenType> acquires FeeBank {
        let user_addr = signer::address_of(user);
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        let fee_bank = borrow_global_mut<FeeBank<FeeTokenType>>(fee_bank_owner);
        
        // Find user credit entry
        let credit_entry = find_credit_entry(&mut fee_bank.credits, user_addr);
        assert!(credit_entry.available_credit >= amount, error::invalid_state(E_INSUFFICIENT_CREDIT));
        
        credit_entry.available_credit = credit_entry.available_credit - amount;
        
        // Emit withdrawal event
        event::emit_event(&mut fee_bank.withdrawal_events, WithdrawalEvent {
            user: user_addr,
            amount,
            remaining_credit: credit_entry.available_credit,
            timestamp: timestamp::now_seconds(),
        });
        
        // Return tokens (simplified - in practice would transfer from bank)
        coin::zero<FeeTokenType>() // Placeholder for actual withdrawal logic
    }

    /// Charges a fee from resolver's credits
    public fun charge_resolver_fee<FeeTokenType>(
        fee_bank_owner: address,
        resolver: address,
        fee_amount: u64
    ) acquires FeeBank {
        if (fee_amount == 0) return;
        
        let fee_bank = borrow_global_mut<FeeBank<FeeTokenType>>(fee_bank_owner);
        
        let credit_entry = find_credit_entry(&mut fee_bank.credits, resolver);
        assert!(credit_entry.available_credit >= fee_amount, error::invalid_state(E_INSUFFICIENT_CREDIT));
        
        credit_entry.available_credit = credit_entry.available_credit - fee_amount;
        credit_entry.total_fees_paid = credit_entry.total_fees_paid + fee_amount;
        
        fee_bank.total_fees_collected = fee_bank.total_fees_collected + fee_amount;
        
        // Emit fee charge event
        event::emit_event(&mut fee_bank.fee_charge_events, FeeChargeEvent {
            resolver,
            fee_amount,
            remaining_credit: credit_entry.available_credit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Calculates resolver fee based on order details
    public fun calculate_resolver_fee(
        config: &FeeConfig,
        order_making_amount: u64,
        actual_making_amount: u64
    ): u64 {
        if (!config.resolver_fee_enabled) {
            return 0
        };
        
        // fee = base_fee * ORDER_FEE_BASE_POINTS * actual_making_amount / order_making_amount
        let fee = ((config.base_resolver_fee as u256) * ORDER_FEE_BASE_POINTS * (actual_making_amount as u256)) 
                  / (order_making_amount as u256);
        (fee as u64)
    }

    /// Validates if resolver is whitelisted at current time
    public fun is_resolver_whitelisted(
        whitelist: &ResolverWhitelist,
        resolver: address
    ): bool {
        let current_time = timestamp::now_seconds();
        let resolver_masked = get_address_mask(resolver);
        
        let allowed_time = whitelist.allowed_time;
        let resolvers_len = vector::length(&whitelist.resolvers);
        let i = 0;
        
        while (i < resolvers_len) {
            let whitelisted = vector::borrow(&whitelist.resolvers, i);
            allowed_time = allowed_time + (whitelisted.time_delta as u64);
            
            if (whitelisted.resolver_address_masked == resolver_masked) {
                return allowed_time <= current_time
            };
            
            if (allowed_time > current_time) {
                return false
            };
            
            i = i + 1;
        };
        
        false
    }

    /// Validates resolver access (whitelist or access token)
    public fun validate_resolver_access<AccessTokenType>(
        whitelist: &ResolverWhitelist,
        resolver: address,
        access_token_config_addr: address,
        fee_config: &FeeConfig,
        fee_bank_owner: address
    ) acquires AccessTokenConfig, FeeBank {
        let current_time = timestamp::now_seconds();
        
        // Check whitelist first
        if (is_resolver_whitelisted(whitelist, resolver)) {
            return // Whitelisted resolvers don't pay fees
        };
        
        // Check if allowed time has passed and resolver has access token
        if (whitelist.allowed_time > current_time) {
            abort error::permission_denied(E_RESOLVER_NOT_ALLOWED)
        };
        
        // Check access token balance
        if (exists<AccessTokenConfig<AccessTokenType>>(access_token_config_addr)) {
            let access_config = borrow_global<AccessTokenConfig<AccessTokenType>>(access_token_config_addr);
            let resolver_balance = coin::balance<AccessTokenType>(resolver);
            
            if (resolver_balance < access_config.min_balance_required) {
                abort error::permission_denied(E_RESOLVER_NOT_ALLOWED)
            };
            
            // Charge fee if enabled
            if (fee_config.resolver_fee_enabled) {
                charge_resolver_fee<AccessTokenType>(fee_bank_owner, resolver, fee_config.base_resolver_fee);
            };
        } else {
            abort error::permission_denied(E_RESOLVER_NOT_ALLOWED)
        };
    }

    /// Helper function to get address mask (last 10 bytes)
    fun get_address_mask(addr: address): u128 {
        let addr_bytes = std::bcs::to_bytes(&addr);
        let addr_len = vector::length(&addr_bytes);
        
        // Extract last 10 bytes (80 bits) as u128
        let result = 0u128;
        let start_idx = if (addr_len >= 10) { addr_len - 10 } else { 0 };
        let i = start_idx;
        
        while (i < addr_len) {
            result = (result << 8) + (*vector::borrow(&addr_bytes, i) as u128);
            i = i + 1;
        };
        
        result
    }

    /// Helper function to find or create credit entry
    fun find_or_create_credit_entry(credits: &mut vector<CreditEntry>, user: address): &mut CreditEntry {
        let credits_len = vector::length(credits);
        let i = 0;
        
        while (i < credits_len) {
            let entry = vector::borrow_mut(credits, i);
            if (entry.user == user) {
                return entry
            };
            i = i + 1;
        };
        
        // Create new entry
        vector::push_back(credits, CreditEntry {
            user,
            available_credit: 0,
            total_deposited: 0,
            total_fees_paid: 0,
        });
        
        let len = vector::length(credits);
        vector::borrow_mut(credits, len - 1)
    }

    /// Helper function to find credit entry
    fun find_credit_entry(credits: &mut vector<CreditEntry>, user: address): &mut CreditEntry {
        let credits_len = vector::length(credits);
        let i = 0;
        
        while (i < credits_len) {
            let entry = vector::borrow_mut(credits, i);
            if (entry.user == user) {
                return entry
            };
            i = i + 1;
        };
        
        abort error::not_found(E_INVALID_RESOLVER)
    }

    // View functions
    public fun get_available_credit<FeeTokenType>(
        fee_bank_owner: address,
        user: address
    ): u64 acquires FeeBank {
        if (!exists<FeeBank<FeeTokenType>>(fee_bank_owner)) {
            return 0
        };
        
        let fee_bank = borrow_global<FeeBank<FeeTokenType>>(fee_bank_owner);
        let credits_len = vector::length(&fee_bank.credits);
        let i = 0;
        
        while (i < credits_len) {
            let entry = vector::borrow(&fee_bank.credits, i);
            if (entry.user == user) {
                return entry.available_credit
            };
            i = i + 1;
        };
        
        0
    }

    public fun get_total_fees_paid<FeeTokenType>(
        fee_bank_owner: address,
        user: address
    ): u64 acquires FeeBank {
        if (!exists<FeeBank<FeeTokenType>>(fee_bank_owner)) {
            return 0
        };
        
        let fee_bank = borrow_global<FeeBank<FeeTokenType>>(fee_bank_owner);
        let credits_len = vector::length(&fee_bank.credits);
        let i = 0;
        
        while (i < credits_len) {
            let entry = vector::borrow(&fee_bank.credits, i);
            if (entry.user == user) {
                return entry.total_fees_paid
            };
            i = i + 1;
        };
        
        0
    }

    // Factory functions for configurations
    public fun new_resolver_whitelist(
        allowed_time: u64,
        resolvers: vector<WhitelistedResolver>
    ): ResolverWhitelist {
        ResolverWhitelist {
            allowed_time,
            resolvers,
        }
    }

    public fun new_whitelisted_resolver(
        resolver_address: address,
        time_delta: u16
    ): WhitelistedResolver {
        WhitelistedResolver {
            resolver_address_masked: get_address_mask(resolver_address),
            time_delta,
        }
    }

    public fun new_fee_config(
        resolver_fee_enabled: bool,
        base_resolver_fee: u64,
        fee_rate: u64
    ): FeeConfig {
        FeeConfig {
            resolver_fee_enabled,
            base_resolver_fee,
            fee_rate,
        }
    }

    // Getter functions
    public fun get_fee_enabled(config: &FeeConfig): bool { config.resolver_fee_enabled }
    public fun get_base_fee(config: &FeeConfig): u64 { config.base_resolver_fee }
    public fun get_fee_rate(config: &FeeConfig): u64 { config.fee_rate }
}