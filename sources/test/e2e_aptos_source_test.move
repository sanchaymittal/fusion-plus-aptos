#[test_only]
module crosschain_escrow_factory::e2e_aptos_source_test {
    use std::signer;
    use std::vector;
    use std::string;
    use aptos_std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use token_addr::mock_token::{Self, MockToken};
    use aptos_framework::timestamp;
    use crosschain_escrow_factory::escrow_factory;
    use crosschain_escrow_factory::escrow_core;
    use crosschain_escrow_factory::timelock;
    use crosschain_escrow_factory::dutch_auction;
    use crosschain_escrow_factory::fee_bank;
    use crosschain_escrow_factory::merkle_validator;

    fun setup_test(admin: &signer, maker: &signer, resolver: &signer) {
        // Safe initialize - always succeeds for mock token
        mock_token::safe_initialize(
            admin,
            b"Mock Token",
            b"MCK",
            8,
            true
        );
        
        // Register accounts
        mock_token::register(maker);
        mock_token::register(resolver);
        // Note: AptosCoin registration handled by test framework
        
        // Mint mock tokens to maker for testing
        mock_token::mint(admin, signer::address_of(maker), 1000000);
    }

    /// Test E2E flow: Aptos (source) -> Ethereum (destination)
    /// Scenario: Maker signs order on Aptos, resolver creates source escrow on Aptos,
    /// then resolver withdraws after destination escrow on Ethereum is filled
    #[test(framework = @aptos_framework, admin = @crosschain_escrow_factory, resolver = @resolver_addr, maker = @0x123, user = @0x456)]
    fun test_e2e_aptos_to_ethereum_swap(
        framework: &signer,
        admin: &signer,
        resolver: &signer,
        maker: &signer, 
        user: &signer
    ) {
        debug::print(&string::utf8(b"=== E2E Test: Aptos -> Ethereum Swap ==="));
        
        // Setup: Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1700000000);
        
        // Step 1: Initialize token system
        debug::print(&string::utf8(b"Step 1: Initializing token system..."));
        setup_test(admin, maker, resolver);
        
        let initial_maker_balance = mock_token::balance(signer::address_of(maker));
        let initial_resolver_balance = mock_token::balance(signer::address_of(resolver));
        
        debug::print(&string::utf8(b"Initial maker token balance:"));
        debug::print(&initial_maker_balance);
        debug::print(&string::utf8(b"Initial resolver token balance:"));
        debug::print(&initial_resolver_balance);
        
        // Step 2: Initialize factory
        debug::print(&string::utf8(b"Step 2: Initializing factory..."));
        
        escrow_factory::initialize<AptosCoin, MockToken>(
            admin,
            3600, // src_rescue_delay
            7200, // dst_rescue_delay
            signer::address_of(admin), // fee_bank_owner
            signer::address_of(admin)  // access_token_config_addr
        );
        
        // Step 3: Create mock order data (as if maker signed an order)
        debug::print(&string::utf8(b"Step 3: Creating order data..."));
        
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, b"aptos_to_eth_order_hash_32_byte");
        
        let secret = vector::empty<u8>();
        vector::append(&mut secret, b"secret_for_aptos_to_ethereum_swap");
        
        let hashlock = vector::empty<u8>();
        vector::append(&mut hashlock, b"secret_for_aptos_to_ethereum_swap"); // In reality, hash(secret)
        
        let maker_addr = signer::address_of(maker);
        let taker_addr = signer::address_of(resolver); // Resolver is the taker
        let making_amount = 50000; // 50k tokens on Aptos
        let taking_amount = 49000; // 49k USDC on Ethereum (with spread)
        let safety_deposit_amount = 1000;
        
        // Step 4: Prepare order data structure
        debug::print(&string::utf8(b"Step 4: Preparing order data..."));
        
        let current_time = timestamp::now_seconds();
        
        // Create order data (simplified version)
        let order_data = escrow_factory::new_order_data(
            order_hash,
            maker_addr,
            @0x0, // receiver (0x0 means same as maker)
            string::utf8(b"MockToken"), // maker_asset
            string::utf8(b"USDC"), // taker_asset  
            making_amount,
            taking_amount
        );
        
        // Create timelocks
        let timelocks = timelock::new(
            10,   // src_withdrawal_delay
            120,  // src_public_withdrawal_delay
            121,  // src_cancellation_delay
            122,  // src_public_cancellation_delay
            10,   // dst_withdrawal_delay
            100,  // dst_public_withdrawal_delay
            101   // dst_cancellation_delay
        );
        
        // Create auction config (no auction for simplicity)
        let auction_config = dutch_auction::new_auction_config(
            0,        // gas_bump_estimate
            100,      // gas_price_estimate  
            (current_time as u32), // start_time
            120,      // duration
            0,        // initial_rate_bump
            vector::empty() // auction_points
        );
        
        // Create fee config (no fees for testing)
        let fee_config = fee_bank::new_fee_config(
            false, // resolver_fee_enabled
            0,     // base_resolver_fee
            0      // fee_rate
        );
        
        // Create whitelist (allow resolver)
        let whitelisted_resolver = fee_bank::new_whitelisted_resolver(taker_addr, 0);
        let whitelist = fee_bank::new_resolver_whitelist(
            0, // allowed_time
            vector::singleton(whitelisted_resolver) // resolvers
        );
        
        // Create taker data (for single fill)
        let taker_data = merkle_validator::new_taker_data(
            vector::empty(), // proof (empty for single fill)
            0,               // index
            hashlock         // secret_hash
        );
        
        // Step 5: Create source escrow args
        debug::print(&string::utf8(b"Step 5: Creating source escrow..."));
        
        let deposits = ((safety_deposit_amount as u128) << 64) | (safety_deposit_amount as u128);
        
        let src_escrow_args = escrow_factory::new_src_escrow_args(
            order_hash,
            hashlock,
            1, // dst_chain_id (Ethereum)
            string::utf8(b"USDC"), // dst_token
            deposits,
            timelocks,
            auction_config,
            fee_config,
            whitelist,
            taker_data
        );
        
        // Step 6: Simulate order fill (resolver fills the order)
        debug::print(&string::utf8(b"Step 6: Simulating order fill..."));
        
        // In a real scenario, this would be called by the limit order protocol
        // For testing, we simulate the source escrow creation
        let escrow_addr = escrow_factory::create_src_escrow<MockToken, AptosCoin, MockToken>(
            signer::address_of(admin), // factory_addr
            &order_data,
            taker_addr, // taker (resolver)
            making_amount,
            taking_amount,
            0, // remaining_making_amount (fully filled)
            src_escrow_args
        );
        
        debug::print(&string::utf8(b"Source escrow created at:"));
        debug::print(&escrow_addr);
        
        // Step 7: Simulate destination escrow creation on Ethereum
        debug::print(&string::utf8(b"Step 7: Simulating destination escrow creation on Ethereum..."));
        debug::print(&string::utf8(b"(In real world, resolver would create escrow on Ethereum here)"));
        
        // Step 8: Simulate passage of time (finality delay)
        debug::print(&string::utf8(b"Step 8: Waiting for finality delay..."));
        timestamp::update_global_time_for_test_secs(current_time + 15);
        
        // Step 9: Simulate user revealing secret on destination chain
        debug::print(&string::utf8(b"Step 9: User reveals secret on Ethereum, resolver withdraws on Aptos..."));
        
        // Reconstruct immutables for withdrawal
        let token_type_string = string::utf8(b"0x200::mock_token::MockToken");
        let timelocks_with_time = timelock::with_deployed_at(timelocks, current_time);
        
        let immutables = escrow_core::new_immutables(
            order_hash,
            hashlock,
            maker_addr,
            taker_addr,
            token_type_string,
            making_amount,
            safety_deposit_amount,
            timelocks_with_time
        );
        
        // Resolver withdraws from source escrow using the secret
        escrow_core::withdraw<MockToken>(
            resolver,
            escrow_addr,
            secret,
            immutables,
            signer::address_of(resolver) // recipient
        );
        
        // Step 10: Verify final balances
        debug::print(&string::utf8(b"Step 10: Verifying final balances..."));
        
        let final_maker_balance = mock_token::balance(signer::address_of(maker));
        let final_resolver_balance = mock_token::balance(signer::address_of(resolver));
        
        debug::print(&string::utf8(b"Final maker balance:"));
        debug::print(&final_maker_balance);
        debug::print(&string::utf8(b"Final resolver balance:"));
        debug::print(&final_resolver_balance);
        
        // Assertions
        // Maker should have transferred tokens to escrow (which resolver now has)
        assert!(final_resolver_balance == initial_resolver_balance + making_amount, 1);
        
        debug::print(&string::utf8(b"SUCCESS: E2E Test Passed: Aptos -> Ethereum swap completed successfully!"));
    }
    
    /// Test cancellation flow for source escrow
    #[test(framework = @aptos_framework, admin = @crosschain_escrow_factory, resolver = @resolver_addr, maker = @0x123)]
    fun test_e2e_aptos_source_cancellation(
        framework: &signer,
        admin: &signer,
        resolver: &signer,
        maker: &signer
    ) {
        debug::print(&string::utf8(b"=== E2E Test: Aptos Source Cancellation ==="));
        
        // Setup similar to successful test
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1700000000);
        
        setup_test(admin, maker, resolver);
        
        escrow_factory::initialize<AptosCoin, MockToken>(
            admin, 3600, 7200, signer::address_of(admin), signer::address_of(admin)
        );
        
        let initial_maker_balance = mock_token::balance(signer::address_of(maker));
        
        // Create order and escrow (similar setup as successful test)
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, b"cancellation_order_hash_32_byte");
        
        let hashlock = vector::empty<u8>();
        vector::append(&mut hashlock, b"secret_that_wont_be_revealed___");
        
        let current_time = timestamp::now_seconds();
        let making_amount = 25000;
        let safety_deposit_amount = 1000;
        
        // Create escrow args with shorter timeouts for testing cancellation
        let timelocks = timelock::new(10, 60, 61, 62, 10, 50, 51); // Shorter timeouts
        let auction_config = dutch_auction::new_auction_config(0, 100, (current_time as u32), 60, 0, vector::empty());
        let fee_config = fee_bank::new_fee_config(false, 0, 0);
        let whitelisted_resolver = fee_bank::new_whitelisted_resolver(signer::address_of(resolver), 0);
        let whitelist = fee_bank::new_resolver_whitelist(
            0, // allowed_time
            vector::singleton(whitelisted_resolver) // resolvers
        );
        let taker_data = merkle_validator::new_taker_data(vector::empty(), 0, hashlock);
        let deposits = ((safety_deposit_amount as u128) << 64) | (safety_deposit_amount as u128);
        
        let src_escrow_args = escrow_factory::new_src_escrow_args(
            order_hash, hashlock, 1, string::utf8(b"USDC"), deposits,
            timelocks, auction_config, fee_config, whitelist, taker_data
        );
        
        let order_data = escrow_factory::new_order_data(
            order_hash, signer::address_of(maker), @0x0,
            string::utf8(b"MockToken"), string::utf8(b"USDC"),
            making_amount, 24000
        );
        
        let escrow_addr = escrow_factory::create_src_escrow<MockToken, AptosCoin, MockToken>(
            signer::address_of(admin), &order_data,
            signer::address_of(resolver), making_amount, 24000, 0, src_escrow_args
        );
        
        // Wait past cancellation time
        timestamp::update_global_time_for_test_secs(current_time + 70);
        
        // Cancel the escrow (maker can cancel after timeout)
        let token_type_string = string::utf8(b"0x200::mock_token::MockToken");
        let timelocks_with_time = timelock::with_deployed_at(timelocks, current_time);
        let immutables = escrow_core::new_immutables(
            order_hash, hashlock,
            signer::address_of(maker), signer::address_of(resolver),
            token_type_string, making_amount, safety_deposit_amount, timelocks_with_time
        );
        
        escrow_core::cancel<MockToken>(maker, escrow_addr, immutables);
        
        // Verify maker got their tokens back
        let final_maker_balance = mock_token::balance(signer::address_of(maker));
        debug::print(&string::utf8(b"Final maker balance after cancellation:"));
        debug::print(&final_maker_balance);
        
        // After cancellation, maker should have their original balance back
        assert!(final_maker_balance == initial_maker_balance, 2);
        
        debug::print(&string::utf8(b"SUCCESS: E2E Test Passed: Aptos source cancellation completed successfully!"));
    }
}