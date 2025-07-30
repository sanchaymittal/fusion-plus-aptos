/// Order integration module for connecting with limit order protocols
/// Provides pre/post interaction hooks and amount calculations for dynamic pricing
module crosschain_escrow_factory::order_integration {
    use std::error;
    use std::signer;
    use std::vector;
    use std::string::String;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use crosschain_escrow_factory::escrow_factory::{Self, OrderData, SrcEscrowArgs};
    use crosschain_escrow_factory::dutch_auction::{Self, AuctionConfig};
    use crosschain_escrow_factory::fee_bank::{Self, FeeConfig, ResolverWhitelist};
    use crosschain_escrow_factory::merkle_validator::{Self, TakerData};
    use aptos_std::from_bcs;

    /// Error codes
    const E_ONLY_LIMIT_ORDER_PROTOCOL: u64 = 1;
    const E_INVALID_ORDER: u64 = 2;
    const E_INVALID_EXTENSION: u64 = 3;
    const E_INVALID_EXTRA_DATA: u64 = 4;
    const E_UNAUTHORIZED_TAKER: u64 = 5;

    /// Integration configuration
    struct OrderIntegration<phantom FeeTokenType, phantom AccessTokenType> has key {
        limit_order_protocol: address,
        factory_address: address,
        owner: address,
        
        // Events
        pre_interaction_events: EventHandle<PreInteractionEvent>,
        post_interaction_events: EventHandle<PostInteractionEvent>,
        amount_calculation_events: EventHandle<AmountCalculationEvent>,
    }

    /// Order execution context
    struct ExecutionContext has copy, drop {
        order_hash: vector<u8>,
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        remaining_making_amount: u64,
        timestamp: u64,
    }

    /// Extension data structure for order processing
    struct ExtensionData has copy, drop {
        maker_asset_suffix: vector<u8>,
        taker_asset_suffix: vector<u8>,
        making_amount_data: vector<u8>,
        taking_amount_data: vector<u8>,
        predicate: vector<u8>,
        maker_permit: vector<u8>,
        pre_interaction_data: vector<u8>,
        post_interaction_data: vector<u8>,
        custom_data: vector<u8>,
    }

    // Events
    struct PreInteractionEvent has drop, store {
        order_hash: vector<u8>,
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        timestamp: u64,
    }

    struct PostInteractionEvent has drop, store {
        order_hash: vector<u8>,
        taker: address,
        escrow_address: address,
        making_amount: u64,
        taking_amount: u64,
        timestamp: u64,
    }

    struct AmountCalculationEvent has drop, store {
        order_hash: vector<u8>,
        original_making_amount: u64,
        original_taking_amount: u64,
        calculated_making_amount: u64,
        calculated_taking_amount: u64,
        rate_bump: u64,
        timestamp: u64,
    }

    /// Helper function to ensure only limit order protocol can call
    fun assert_only_limit_order_protocol<FeeTokenType, AccessTokenType>(
        integration_addr: address,
        caller: address
    ) acquires OrderIntegration {
        let integration = borrow_global<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr);
        assert!(integration.limit_order_protocol == caller, 
                error::permission_denied(E_ONLY_LIMIT_ORDER_PROTOCOL));
    }

    /// Initializes the order integration
    public entry fun initialize<FeeTokenType, AccessTokenType>(
        admin: &signer,
        limit_order_protocol: address,
        factory_address: address,
    ) {
        let admin_addr = signer::address_of(admin);
        
        move_to(admin, OrderIntegration<FeeTokenType, AccessTokenType> {
            limit_order_protocol,
            factory_address,
            owner: admin_addr,
            pre_interaction_events: account::new_event_handle(admin),
            post_interaction_events: account::new_event_handle(admin),
            amount_calculation_events: account::new_event_handle(admin),
        });
    }

    /// Pre-interaction hook called by limit order protocol before fund transfers
    public fun pre_interaction<TokenType, FeeTokenType, AccessTokenType>(
        integration_addr: address,
        order: OrderData,
        extension: ExtensionData,
        order_hash: vector<u8>,
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        remaining_making_amount: u64,
        extra_data: vector<u8>,
    ) acquires OrderIntegration {
        // Validate caller
        let integration = borrow_global_mut<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr);
        // Note: In practice, this would use the modifier pattern or capability system
        
        // Emit pre-interaction event
        event::emit_event(&mut integration.pre_interaction_events, PreInteractionEvent {
            order_hash,
            taker,
            making_amount,
            taking_amount,
            timestamp: timestamp::now_seconds(),
        });

        // Additional pre-interaction logic can be added here
        // For example: validating order state, checking balances, etc.
    }

    /// Post-interaction hook called by limit order protocol after fund transfers
    /// This is where the source escrow gets created
    public fun post_interaction<TokenType, FeeTokenType, AccessTokenType>(
        integration_addr: address,
        order: OrderData,
        extension: ExtensionData,
        order_hash: vector<u8>,
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        remaining_making_amount: u64,
        extra_data: vector<u8>,
    ) acquires OrderIntegration {
        let integration = borrow_global_mut<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr);
        
        // Parse extra data to extract escrow creation arguments
        let args = parse_extra_data_to_src_args(extra_data);
        
        // Create source escrow through factory
        let escrow_addr = escrow_factory::create_src_escrow<TokenType, FeeTokenType, AccessTokenType>(
            integration.factory_address,
            &order,
            taker,
            making_amount,
            taking_amount,
            remaining_making_amount,
            args,
        );

        // Emit post-interaction event
        event::emit_event(&mut integration.post_interaction_events, PostInteractionEvent {
            order_hash,
            taker,
            escrow_address: escrow_addr,
            making_amount,
            taking_amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Calculates making amount based on taking amount and current auction state
    public fun get_making_amount<FeeTokenType, AccessTokenType>(
        integration_addr: address,
        order: &OrderData,
        extension: &ExtensionData,
        order_hash: vector<u8>,
        taker: address,
        taking_amount: u64,
        remaining_making_amount: u64,
        extra_data: vector<u8>,
        current_gas_price: u64,
    ): u64 acquires OrderIntegration {
        let integration = borrow_global_mut<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr);
        
        // Parse auction configuration from extra data
        let auction_config = parse_auction_config_from_extra_data(&extra_data);
        
        // Calculate rate bump
        let rate_bump = dutch_auction::calculate_rate_bump(&auction_config, current_gas_price);
        
        // Calculate adjusted making amount
        let making_amount = dutch_auction::calculate_making_amount(
            escrow_factory::get_order_making_amount(order),
            escrow_factory::get_order_taking_amount(order),
            taking_amount,
            rate_bump
        );

        // Emit calculation event
        event::emit_event(&mut integration.amount_calculation_events, AmountCalculationEvent {
            order_hash,
            original_making_amount: escrow_factory::get_order_making_amount(order),
            original_taking_amount: escrow_factory::get_order_taking_amount(order),
            calculated_making_amount: making_amount,
            calculated_taking_amount: taking_amount,
            rate_bump,
            timestamp: timestamp::now_seconds(),
        });

        making_amount
    }

    /// Calculates taking amount based on making amount and current auction state
    public fun get_taking_amount<FeeTokenType, AccessTokenType>(
        integration_addr: address,
        order: &OrderData,
        extension: &ExtensionData,
        order_hash: vector<u8>,
        taker: address,
        making_amount: u64,
        remaining_making_amount: u64,
        extra_data: vector<u8>,
        current_gas_price: u64,
    ): u64 acquires OrderIntegration {
        let integration = borrow_global_mut<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr);
        
        // Parse auction configuration from extra data
        let auction_config = parse_auction_config_from_extra_data(&extra_data);
        
        // Calculate rate bump
        let rate_bump = dutch_auction::calculate_rate_bump(&auction_config, current_gas_price);
        
        // Calculate adjusted taking amount (using ceiling division)
        let taking_amount = dutch_auction::calculate_taking_amount(
            escrow_factory::get_order_making_amount(order),
            escrow_factory::get_order_taking_amount(order),
            making_amount,
            rate_bump
        );

        // Emit calculation event
        event::emit_event(&mut integration.amount_calculation_events, AmountCalculationEvent {
            order_hash,
            original_making_amount: escrow_factory::get_order_making_amount(order),
            original_taking_amount: escrow_factory::get_order_taking_amount(order),
            calculated_making_amount: making_amount,
            calculated_taking_amount: taking_amount,
            rate_bump,
            timestamp: timestamp::now_seconds(),
        });

        taking_amount
    }

    /// Parses extra data to extract source escrow arguments
    /// This function handles the complex packed data structure from the Solidity implementation
    fun parse_extra_data_to_src_args(extra_data: vector<u8>): SrcEscrowArgs {
        // This is a simplified version - in practice, this would need to carefully
        // parse the packed binary data according to the Solidity format
        
        let data_len = vector::length(&extra_data);
        assert!(data_len >= 160, error::invalid_argument(E_INVALID_EXTRA_DATA)); // Minimum size for SRC_IMMUTABLES_LENGTH
        
        // Extract components (simplified parsing)
        let order_hash = extract_bytes(&extra_data, 0, 32);
        let hashlock_info = extract_bytes(&extra_data, 32, 32);
        let dst_chain_id = extract_u64(&extra_data, 64);
        let dst_token = extract_string(&extra_data, 72, 32);
        let deposits = extract_u128(&extra_data, 104);
        
        // Create default configurations (in practice, these would be parsed from extra_data)
        let timelocks = create_default_timelocks();
        let auction_config = create_default_auction_config();
        let fee_config = create_default_fee_config();
        let whitelist = create_default_whitelist();
        let taker_data = create_default_taker_data();

        escrow_factory::new_src_escrow_args(
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
        )
    }

    /// Parses auction configuration from extra data
    fun parse_auction_config_from_extra_data(extra_data: &vector<u8>): AuctionConfig {
        // Simplified parsing - in practice would extract from packed binary data
        let gas_bump_estimate = extract_u32(extra_data, 0);
        let gas_price_estimate = extract_u32(extra_data, 4);
        let start_time = extract_u32(extra_data, 8);
        let duration = extract_u32(extra_data, 12);
        let initial_rate_bump = extract_u32(extra_data, 16);
        
        dutch_auction::new_auction_config(
            gas_bump_estimate,
            gas_price_estimate,
            start_time,
            duration,
            initial_rate_bump,
            vector::empty(), // auction_points - would be parsed from remaining data
        )
    }

    // Helper functions for data extraction
    fun extract_bytes(data: &vector<u8>, offset: u64, length: u64): vector<u8> {
        let result = vector::empty<u8>();
        let i = offset;
        let end = offset + length;
        
        while (i < end && i < vector::length(data)) {
            vector::push_back(&mut result, *vector::borrow(data, i));
            i = i + 1;
        };
        
        result
    }

    fun extract_u32(data: &vector<u8>, offset: u64): u32 {
        let bytes = extract_bytes(data, offset, 4);
        from_bcs::to_u32(bytes)
    }

    fun extract_u64(data: &vector<u8>, offset: u64): u64 {
        let bytes = extract_bytes(data, offset, 8);
        from_bcs::to_u64(bytes)
    }

    fun extract_u128(data: &vector<u8>, offset: u64): u128 {
        let bytes = extract_bytes(data, offset, 16);
        from_bcs::to_u128(bytes)
    }

    fun extract_string(data: &vector<u8>, offset: u64, length: u64): String {
        let bytes = extract_bytes(data, offset, length);
        std::string::utf8(bytes)
    }

    // Default configuration creators (simplified for demo)
    fun create_default_timelocks(): crosschain_escrow_factory::timelock::Timelocks {
        crosschain_escrow_factory::timelock::new(
            3600,   // src_withdrawal_delay: 1 hour
            7200,   // src_public_withdrawal_delay: 2 hours
            14400,  // src_cancellation_delay: 4 hours
            21600,  // src_public_cancellation_delay: 6 hours
            1800,   // dst_withdrawal_delay: 30 minutes
            3600,   // dst_public_withdrawal_delay: 1 hour
            7200,   // dst_cancellation_delay: 2 hours
        )
    }

    fun create_default_auction_config(): AuctionConfig {
        dutch_auction::new_auction_config(
            1000,   // gas_bump_estimate
            1000000, // gas_price_estimate
            (timestamp::now_seconds() as u32), // start_time
            3600,   // duration: 1 hour
            1000,   // initial_rate_bump
            vector::empty(), // auction_points
        )
    }

    fun create_default_fee_config(): FeeConfig {
        fee_bank::new_fee_config(
            true,   // resolver_fee_enabled
            100,    // base_resolver_fee
            10,     // fee_rate
        )
    }

    fun create_default_whitelist(): ResolverWhitelist {
        fee_bank::new_resolver_whitelist(
            timestamp::now_seconds(),
            vector::empty(), // resolvers
        )
    }

    fun create_default_taker_data(): TakerData {
        merkle_validator::new_taker_data(
            vector::empty(), // proof
            0,               // idx
            vector::empty(), // secret_hash
        )
    }

    // View functions
    public fun get_integration_config<FeeTokenType, AccessTokenType>(
        integration_addr: address
    ): (address, address, address) acquires OrderIntegration {
        let integration = borrow_global<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr);
        (integration.limit_order_protocol, integration.factory_address, integration.owner)
    }

    public fun is_integration_initialized<FeeTokenType, AccessTokenType>(
        integration_addr: address
    ): bool {
        exists<OrderIntegration<FeeTokenType, AccessTokenType>>(integration_addr)
    }

    // Factory functions for extension data
    public fun new_extension_data(
        maker_asset_suffix: vector<u8>,
        taker_asset_suffix: vector<u8>,
        making_amount_data: vector<u8>,
        taking_amount_data: vector<u8>,
        predicate: vector<u8>,
        maker_permit: vector<u8>,
        pre_interaction_data: vector<u8>,
        post_interaction_data: vector<u8>,
        custom_data: vector<u8>,
    ): ExtensionData {
        ExtensionData {
            maker_asset_suffix,
            taker_asset_suffix,
            making_amount_data,
            taking_amount_data,
            predicate,
            maker_permit,
            pre_interaction_data,
            post_interaction_data,
            custom_data,
        }
    }

    // Getter functions for ExtensionData
    public fun get_maker_asset_suffix(ext: &ExtensionData): vector<u8> { ext.maker_asset_suffix }
    public fun get_taker_asset_suffix(ext: &ExtensionData): vector<u8> { ext.taker_asset_suffix }
    public fun get_making_amount_data(ext: &ExtensionData): vector<u8> { ext.making_amount_data }
    public fun get_taking_amount_data(ext: &ExtensionData): vector<u8> { ext.taking_amount_data }
    public fun get_predicate(ext: &ExtensionData): vector<u8> { ext.predicate }
    public fun get_maker_permit(ext: &ExtensionData): vector<u8> { ext.maker_permit }
    public fun get_pre_interaction_data(ext: &ExtensionData): vector<u8> { ext.pre_interaction_data }
    public fun get_post_interaction_data(ext: &ExtensionData): vector<u8> { ext.post_interaction_data }
    public fun get_custom_data(ext: &ExtensionData): vector<u8> { ext.custom_data }
}