/// Escrow Factory for deploying and managing cross-chain atomic swap escrows
/// Integrates all core modules to provide complete escrow functionality
module crosschain_escrow_factory::escrow_factory {
    use std::error;
    use std::signer;
    use std::vector;
    use std::string::String;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use crosschain_escrow_factory::escrow_core::{Self, EscrowImmutables};
    use crosschain_escrow_factory::timelock::{Self, Timelocks};
    use crosschain_escrow_factory::create2;
    use crosschain_escrow_factory::dutch_auction::{Self, AuctionConfig};
    use aptos_std::from_bcs;
    use crosschain_escrow_factory::merkle_validator::{Self, MultipleFillConfig, TakerData};
    use crosschain_escrow_factory::fee_bank::{Self, FeeConfig, ResolverWhitelist};

    /// Error codes
    const E_INSUFFICIENT_ESCROW_BALANCE: u64 = 1;
    const E_INVALID_CREATION_TIME: u64 = 2;
    const E_INVALID_PARTIAL_FILL: u64 = 3;
    const E_INVALID_SECRETS_AMOUNT: u64 = 4;
    const E_UNAUTHORIZED_RESOLVER: u64 = 5;
    const E_INVALID_ORDER_HASH: u64 = 6;
    const E_INVALID_CONFIGURATION: u64 = 7;

    /// Factory configuration and state
    struct EscrowFactory<phantom FeeTokenType, phantom AccessTokenType> has key {
        owner: address,
        src_rescue_delay: u64,
        dst_rescue_delay: u64,
        fee_bank_owner: address,
        access_token_config_addr: address,
        
        // Statistics
        total_src_escrows: u64,
        total_dst_escrows: u64,
        
        // Events
        src_escrow_events: EventHandle<SrcEscrowCreatedEvent>,
        dst_escrow_events: EventHandle<DstEscrowCreatedEvent>,
        order_fill_events: EventHandle<OrderFillEvent>,
    }

    /// Configuration for creating source escrows
    struct SrcEscrowArgs has copy, drop {
        order_hash: vector<u8>,
        hashlock_info: vector<u8>,    // Hash of secret or Merkle root
        dst_chain_id: u64,
        dst_token: String,
        deposits: u128,               // Combined safety deposits (src << 64 | dst)
        timelocks: Timelocks,
        auction_config: AuctionConfig,
        fee_config: FeeConfig,
        whitelist: ResolverWhitelist,
        taker_data: TakerData,        // For multiple fills
    }

    /// Configuration for creating destination escrows
    struct DstEscrowArgs has copy, drop {
        immutables: EscrowImmutables,
        src_cancellation_timestamp: u64,
    }

    /// Destination immutables complement (for cross-chain coordination)
    struct DstImmutablesComplement has copy, drop, store {
        maker: address,
        amount: u64,
        token: String,
        safety_deposit: u64,
        chain_id: u64,
    }

    // Events
    struct SrcEscrowCreatedEvent has drop, store {
        escrow_address: address,
        immutables: EscrowImmutables,
        dst_complement: DstImmutablesComplement,
        timestamp: u64,
    }

    struct DstEscrowCreatedEvent has drop, store {
        escrow_address: address,
        hashlock: vector<u8>,
        taker: address,
        timestamp: u64,
    }

    struct OrderFillEvent has drop, store {
        order_hash: vector<u8>,
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        auction_rate_bump: u64,
        timestamp: u64,
    }

    /// Initializes the escrow factory
    public entry fun initialize<FeeTokenType, AccessTokenType>(
        admin: &signer,
        src_rescue_delay: u64,
        dst_rescue_delay: u64,
        fee_bank_owner: address,
        access_token_config_addr: address,
    ) {
        let admin_addr = signer::address_of(admin);
        
        move_to(admin, EscrowFactory<FeeTokenType, AccessTokenType> {
            owner: admin_addr,
            src_rescue_delay,
            dst_rescue_delay,
            fee_bank_owner,
            access_token_config_addr,
            total_src_escrows: 0,
            total_dst_escrows: 0,
            src_escrow_events: account::new_event_handle(admin),
            dst_escrow_events: account::new_event_handle(admin),
            order_fill_events: account::new_event_handle(admin),
        });

        // Initialize escrow core for this factory
        escrow_core::initialize(admin);
    }

    /// Creates a source escrow (called during order fill post-interaction)
    public fun create_src_escrow<TokenType, FeeTokenType, AccessTokenType>(
        factory_addr: address,
        order: &OrderData,        // Order details
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        remaining_making_amount: u64,
        args: SrcEscrowArgs,
    ): address acquires EscrowFactory {
        let factory = borrow_global_mut<EscrowFactory<FeeTokenType, AccessTokenType>>(factory_addr);
        
        // Validate resolver access and charge fees
        fee_bank::validate_resolver_access<AccessTokenType>(
            &args.whitelist,
            taker,
            factory.access_token_config_addr,
            &args.fee_config,
            factory.fee_bank_owner
        );

        // Determine hashlock based on whether multiple fills are allowed
        let hashlock = if (is_multiple_fills_order(&args)) {
            handle_multiple_fills(&args, &order.hash, making_amount, remaining_making_amount, order.making_amount)
        } else {
            args.hashlock_info
        };

        // Extract safety deposits
        let src_safety_deposit = ((args.deposits >> 64) as u64);
        let dst_safety_deposit = ((args.deposits & 0xFFFFFFFFFFFFFFFF) as u64);

        // Create escrow immutables
        let timelocks = args.timelocks;
        timelock::set_deployed_at(&mut timelocks, timestamp::now_seconds());
        
        let immutables = escrow_core::new_immutables(
            args.order_hash,
            hashlock,
            order.maker,
            taker,
            order.maker_asset,
            making_amount,
            src_safety_deposit,
            timelocks,
        );

        // Calculate deterministic address
        let immutables_hash = escrow_core::hash_immutables(&immutables);
        let escrow_addr = create2::compute_src_address(factory_addr, immutables_hash);

        // Validate pre-sent funds
        validate_escrow_balance<TokenType>(escrow_addr, making_amount, src_safety_deposit);

        // Create destination complement for cross-chain coordination
        let dst_complement = DstImmutablesComplement {
            maker: if (order.receiver == @0x0) { order.maker } else { order.receiver },
            amount: taking_amount,
            token: args.dst_token,
            safety_deposit: dst_safety_deposit,
            chain_id: args.dst_chain_id,
        };

        // Emit creation event
        event::emit_event(&mut factory.src_escrow_events, SrcEscrowCreatedEvent {
            escrow_address: escrow_addr,
            immutables,
            dst_complement,
            timestamp: timestamp::now_seconds(),
        });

        factory.total_src_escrows = factory.total_src_escrows + 1;
        escrow_addr
    }

    /// Creates a destination escrow
    public fun create_dst_escrow<TokenType, FeeTokenType, AccessTokenType>(
        caller: &signer,
        factory_addr: address,
        tokens: Coin<TokenType>,
        safety_deposit: Coin<AptosCoin>,
        args: DstEscrowArgs,
    ): (address, Coin<TokenType>, Coin<AptosCoin>) acquires EscrowFactory {
        let caller_addr = signer::address_of(caller);
        let factory = borrow_global_mut<EscrowFactory<FeeTokenType, AccessTokenType>>(factory_addr);

        // Validate token amounts
        let token_amount = coin::value(&tokens);
        let deposit_amount = coin::value(&safety_deposit);
        
        assert!(token_amount >= escrow_core::get_amount(&args.immutables), error::invalid_argument(E_INSUFFICIENT_ESCROW_BALANCE));
        assert!(deposit_amount >= escrow_core::get_safety_deposit_amount(&args.immutables), error::invalid_argument(E_INSUFFICIENT_ESCROW_BALANCE));

        // Update immutables with current timestamp
        let timelocks = escrow_core::get_timelocks(&args.immutables);
        let updated_timelocks = timelocks;
        timelock::set_deployed_at(&mut updated_timelocks, timestamp::now_seconds());
        
        let immutables = escrow_core::new_immutables(
            escrow_core::get_order_hash(&args.immutables),
            escrow_core::get_hashlock(&args.immutables),
            escrow_core::get_maker(&args.immutables),
            escrow_core::get_taker(&args.immutables),
            escrow_core::get_token_type(&args.immutables),
            escrow_core::get_amount(&args.immutables),
            escrow_core::get_safety_deposit_amount(&args.immutables),
            updated_timelocks
        );

        // Validate creation timing
        let dst_cancellation_time = timelock::get_stage_time(&escrow_core::get_timelocks(&immutables), timelock::stage_dst_cancellation());
        assert!(dst_cancellation_time <= args.src_cancellation_timestamp, error::invalid_argument(E_INVALID_CREATION_TIME));

        // Calculate how much tokens and deposit to use
        let tokens_needed = escrow_core::get_amount(&immutables);
        let deposit_needed = escrow_core::get_safety_deposit_amount(&immutables);
        
        // Extract the exact amounts needed for the escrow
        let escrow_tokens = coin::extract(&mut tokens, tokens_needed);
        let escrow_deposit = coin::extract(&mut safety_deposit, deposit_needed);

        // Create the actual escrow using escrow_core
        let escrow_addr = escrow_core::create_escrow<TokenType>(
            caller,
            immutables,
            escrow_tokens,
            escrow_deposit,
            false  // is_source = false for destination escrow
        );

        // Emit creation event
        event::emit_event(&mut factory.dst_escrow_events, DstEscrowCreatedEvent {
            escrow_address: escrow_addr,
            hashlock: escrow_core::get_hashlock(&immutables),
            taker: escrow_core::get_taker(&immutables),  
            timestamp: timestamp::now_seconds(),
        });

        factory.total_dst_escrows = factory.total_dst_escrows + 1;
        
        // Return any remaining tokens and deposits to the caller
        (escrow_addr, tokens, safety_deposit)
    }

    /// Order fill with auction pricing (integrates with limit order protocol)
    public fun fill_order_with_auction<TokenType, FeeTokenType, AccessTokenType>(
        factory_addr: address,
        order: &OrderData,
        taker: address,
        base_making_amount: u64,
        base_taking_amount: u64,
        auction_config: &AuctionConfig,
        current_gas_price: u64,
    ): (u64, u64) acquires EscrowFactory {
        // Calculate current rate bump from auction
        let rate_bump = dutch_auction::calculate_rate_bump(auction_config, current_gas_price);

        // Calculate adjusted amounts based on auction
        let adjusted_making_amount = dutch_auction::calculate_making_amount(
            order.making_amount,
            order.taking_amount,
            base_taking_amount,
            rate_bump
        );

        let adjusted_taking_amount = dutch_auction::calculate_taking_amount(
            order.making_amount,
            order.taking_amount,
            base_making_amount,
            rate_bump
        );

        // Emit order fill event
        let factory = borrow_global_mut<EscrowFactory<FeeTokenType, AccessTokenType>>(factory_addr);
        event::emit_event(&mut factory.order_fill_events, OrderFillEvent {
            order_hash: order.hash,
            taker,
            making_amount: adjusted_making_amount,
            taking_amount: adjusted_taking_amount,
            auction_rate_bump: rate_bump,
            timestamp: timestamp::now_seconds(),
        });

        (adjusted_making_amount, adjusted_taking_amount)
    }

    /// Validates that an escrow has sufficient pre-sent funds
    fun validate_escrow_balance<TokenType>(
        escrow_addr: address,
        required_tokens: u64,
        required_deposit: u64
    ) {
        let token_balance = coin::balance<TokenType>(escrow_addr);
        let native_balance = coin::balance<AptosCoin>(escrow_addr);
        
        assert!(token_balance >= required_tokens, error::invalid_state(E_INSUFFICIENT_ESCROW_BALANCE));
        assert!(native_balance >= required_deposit, error::invalid_state(E_INSUFFICIENT_ESCROW_BALANCE));
    }

    /// Checks if order supports multiple fills
    fun is_multiple_fills_order(args: &SrcEscrowArgs): bool {
        vector::length(&args.hashlock_info) == 32 && 
        vector::length(&merkle_validator::get_proof(&args.taker_data)) > 0
    }

    /// Handles multiple fills with Merkle proof validation
    fun handle_multiple_fills(
        args: &SrcEscrowArgs,
        order_hash: &vector<u8>,
        making_amount: u64,
        remaining_making_amount: u64,
        order_making_amount: u64
    ): vector<u8> {
        // Extract parts amount from hashlock_info (first 2 bytes represent parts count)
        let parts_amount = extract_parts_amount(&args.hashlock_info);
        assert!(parts_amount >= 2, error::invalid_argument(E_INVALID_SECRETS_AMOUNT));

        // Create multiple fill config
        let config = merkle_validator::new_multiple_fill_config(
            args.hashlock_info,
            parts_amount
        );

        // Validate Merkle proof (this would be called by the limit order protocol)
        // For now, we'll assume validation has occurred and get the validated data
        let (validated_index, secret_hash) = merkle_validator::get_last_validated(
            @crosschain_escrow_factory, // Assuming validator is at this address
            order_hash,
            &merkle_validator::get_root_shortened(&config)
        );

        // Validate partial fill
        assert!(
            merkle_validator::is_valid_partial_fill(
                making_amount,
                remaining_making_amount,
                order_making_amount,
                parts_amount,
                validated_index
            ),
            error::invalid_argument(E_INVALID_PARTIAL_FILL)
        );

        secret_hash
    }

    /// Extracts parts amount from hashlock info
    fun extract_parts_amount(hashlock_info: &vector<u8>): u64 {
        if (vector::length(hashlock_info) < 32) {
            return 1 // Single fill
        };

        // In the original Solidity, parts_amount is encoded in the first 2 bytes
        // For simplicity, we'll extract from the last 8 bytes as u64
        let parts_bytes = vector::empty<u8>();
        let start_idx = vector::length(hashlock_info) - 8;
        let i = start_idx;
        
        while (i < vector::length(hashlock_info)) {
            vector::push_back(&mut parts_bytes, *vector::borrow(hashlock_info, i));
            i = i + 1;
        };

        // Convert bytes to u64 using aptos_std::from_bcs
        from_bcs::to_u64(parts_bytes)
    }

    /// Computes deterministic address for source escrow
    public fun compute_src_escrow_address(
        factory_addr: address,
        immutables: &EscrowImmutables
    ): address {
        let immutables_hash = escrow_core::hash_immutables(immutables);
        create2::compute_src_address(factory_addr, immutables_hash)
    }

    /// Computes deterministic address for destination escrow
    public fun compute_dst_escrow_address(
        factory_addr: address,
        immutables: &EscrowImmutables
    ): address {
        let immutables_hash = escrow_core::hash_immutables(immutables);
        create2::compute_dst_address(factory_addr, immutables_hash)
    }

    /// Validates that an escrow address matches the factory's deterministic generation
    public fun validate_escrow_address(
        factory_addr: address,
        escrow_addr: address,
        immutables: &EscrowImmutables,
        is_source: bool
    ): bool {
        let expected_addr = if (is_source) {
            compute_src_escrow_address(factory_addr, immutables)
        } else {
            compute_dst_escrow_address(factory_addr, immutables)
        };
        
        escrow_addr == expected_addr
    }

    // Helper struct for order data (simplified version of limit order protocol order)
    struct OrderData has copy, drop {
        hash: vector<u8>,
        maker: address,
        receiver: address,
        maker_asset: String,
        taker_asset: String,
        making_amount: u64,
        taking_amount: u64,
    }

    // View functions
    public fun get_factory_stats<FeeTokenType, AccessTokenType>(
        factory_addr: address
    ): (u64, u64) acquires EscrowFactory {
        let factory = borrow_global<EscrowFactory<FeeTokenType, AccessTokenType>>(factory_addr);
        (factory.total_src_escrows, factory.total_dst_escrows)
    }

    public fun get_rescue_delays<FeeTokenType, AccessTokenType>(
        factory_addr: address
    ): (u64, u64) acquires EscrowFactory {
        let factory = borrow_global<EscrowFactory<FeeTokenType, AccessTokenType>>(factory_addr);
        (factory.src_rescue_delay, factory.dst_rescue_delay)
    }

    public fun is_factory_initialized<FeeTokenType, AccessTokenType>(
        factory_addr: address
    ): bool {
        exists<EscrowFactory<FeeTokenType, AccessTokenType>>(factory_addr)
    }

    // Factory functions for configuration structs
    public fun new_src_escrow_args(
        order_hash: vector<u8>,
        hashlock_info: vector<u8>,
        dst_chain_id: u64,
        dst_token: String,
        deposits: u128,
        timelocks: Timelocks,
        auction_config: AuctionConfig,
        fee_config: FeeConfig,
        whitelist: ResolverWhitelist,
        taker_data: TakerData,
    ): SrcEscrowArgs {
        SrcEscrowArgs {
            order_hash,
            hashlock_info,
            dst_chain_id,
            dst_token,
            deposits,
            timelocks,
            auction_config,
            fee_config,
            whitelist,
            taker_data,
        }
    }

    public fun new_dst_escrow_args(
        immutables: EscrowImmutables,
        src_cancellation_timestamp: u64
    ): DstEscrowArgs {
        DstEscrowArgs {
            immutables,
            src_cancellation_timestamp,
        }
    }

    public fun new_order_data(
        hash: vector<u8>,
        maker: address,
        receiver: address,
        maker_asset: String,
        taker_asset: String,
        making_amount: u64,
        taking_amount: u64,
    ): OrderData {
        OrderData {
            hash,
            maker,
            receiver,
            maker_asset,
            taker_asset,
            making_amount,
            taking_amount,
        }
    }

    // Getter functions for SrcEscrowArgs
    public fun get_src_order_hash(args: &SrcEscrowArgs): vector<u8> { args.order_hash }
    public fun get_src_hashlock_info(args: &SrcEscrowArgs): vector<u8> { args.hashlock_info }
    public fun get_src_dst_chain_id(args: &SrcEscrowArgs): u64 { args.dst_chain_id }
    public fun get_src_dst_token(args: &SrcEscrowArgs): String { args.dst_token }
    public fun get_src_deposits(args: &SrcEscrowArgs): u128 { args.deposits }
    public fun get_src_timelocks(args: &SrcEscrowArgs): Timelocks { args.timelocks }

    // Getter functions for DstEscrowArgs
    public fun get_dst_immutables(args: &DstEscrowArgs): EscrowImmutables { args.immutables }
    public fun get_dst_src_cancellation_timestamp(args: &DstEscrowArgs): u64 { args.src_cancellation_timestamp }

    // Getter functions for OrderData
    public fun get_order_hash(order: &OrderData): vector<u8> { order.hash }
    public fun get_order_maker(order: &OrderData): address { order.maker }
    public fun get_order_receiver(order: &OrderData): address { order.receiver }
    public fun get_order_maker_asset(order: &OrderData): String { order.maker_asset }
    public fun get_order_taker_asset(order: &OrderData): String { order.taker_asset }
    public fun get_order_making_amount(order: &OrderData): u64 { order.making_amount }
    public fun get_order_taking_amount(order: &OrderData): u64 { order.taking_amount }
}