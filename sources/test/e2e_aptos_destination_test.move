#[test_only]
module crosschain_escrow_factory::e2e_aptos_destination_test {
    use std::signer;
    use std::vector;
    use std::string;
    use aptos_std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use token_addr::mock_token::{Self, MockToken};

    use crosschain_escrow_factory::escrow_factory;
    use crosschain_escrow_factory::escrow_core;
    use crosschain_escrow_factory::timelock;
    use resolver_addr::resolver;

    fun setup_test(admin: &signer, resolver: &signer, user: &signer) {
        // Safe initialize - always succeeds for mock token
        mock_token::safe_initialize(
            admin,
            b"Mock Token",
            b"MCK",
            8,
            true
        );
        
        // Register accounts
        mock_token::register(resolver);
        mock_token::register(user);
        
        // Mint mock tokens to resolver for testing
        mock_token::mint(admin, signer::address_of(resolver), 1000000);
    }

    /// Test E2E flow: Ethereum (source) -> Aptos (destination)
    /// Scenario: Maker signs order on Ethereum, resolver creates destination escrow on Aptos,
    /// then user withdraws using secret after Ethereum source escrow is filled
    #[test(framework = @aptos_framework, admin = @crosschain_escrow_factory, resolver = @resolver_addr, maker = @0x123, user = @0x456)]
    fun test_e2e_ethereum_to_aptos_swap(
        framework: &signer,
        admin: &signer,
        resolver: &signer, 
        maker: &signer,
        user: &signer
    ) {
        debug::print(&string::utf8(b"=== E2E Test: Ethereum -> Aptos Swap ==="));
        
        // Setup: Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1700000000);
        
        // Step 1: Initialize token system
        debug::print(&string::utf8(b"Step 1: Initializing token system..."));
        setup_test(admin, resolver, user);
        
        let initial_resolver_balance = mock_token::balance(signer::address_of(resolver));
        let initial_user_balance = mock_token::balance(signer::address_of(user));
        
        debug::print(&string::utf8(b"Initial resolver token balance:"));
        debug::print(&initial_resolver_balance);
        debug::print(&string::utf8(b"Initial user token balance:"));
        debug::print(&initial_user_balance);
        
        // Step 2: Initialize factory and resolver
        debug::print(&string::utf8(b"Step 2: Initializing factory and resolver..."));
        
        // Initialize escrow factory
        escrow_factory::initialize<AptosCoin, MockToken>(
            admin,
            3600, // src_rescue_delay
            7200, // dst_rescue_delay  
            signer::address_of(admin), // fee_bank_owner
            signer::address_of(admin)  // access_token_config_addr
        );
        
        // Initialize resolver
        resolver::initialize(resolver, signer::address_of(admin));
        
        // Step 3: Simulate Ethereum order fill event
        debug::print(&string::utf8(b"Step 3: Simulating Ethereum order fill..."));
        
        // Mock order data (as if it came from Ethereum)
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, b"ethereum_order_hash_32_bytes_lo");
        
        let secret = vector::empty<u8>();
        vector::append(&mut secret, b"my_secret_password_for_swap_test");
        
        let hashlock = vector::empty<u8>();  
        vector::append(&mut hashlock, b"my_secret_password_for_swap_test"); // In real world, this would be hash(secret)
        
        let maker_addr = signer::address_of(maker);
        let taker_addr = signer::address_of(user);
        let token_amount = 10000;
        let safety_deposit_amount = 1000;
        
        // Step 4: Resolver creates destination escrow on Aptos
        debug::print(&string::utf8(b"Step 4: Creating destination escrow on Aptos..."));
        
        // Prepare timelocks (simulating what would come from Ethereum order)
        let current_time = timestamp::now_seconds();
        
        resolver::deploy_dst_escrow<MockToken, AptosCoin, MockToken>(
            resolver,
            signer::address_of(resolver),
            token_amount,
            safety_deposit_amount,
            // immutables components
            order_hash,
            hashlock,
            maker_addr,
            taker_addr,
            token_amount,
            safety_deposit_amount,
            // timelocks components  
            10,   // src_withdrawal_delay
            120,  // src_public_withdrawal_delay
            121,  // src_cancellation_delay
            122,  // src_public_cancellation_delay
            10,   // dst_withdrawal_delay
            100,  // dst_public_withdrawal_delay
            101,  // dst_cancellation_delay
            current_time, // deployed_at
            current_time + 3600 // src_cancellation_timestamp
        );
        
        debug::print(&string::utf8(b"Destination escrow created successfully!"));
        
        // Check resolver balance after escrow creation
        let resolver_balance_after_escrow = mock_token::balance(signer::address_of(resolver));
        debug::print(&string::utf8(b"Resolver balance after escrow creation:"));
        debug::print(&resolver_balance_after_escrow);
        
        assert!(resolver_balance_after_escrow == initial_resolver_balance - token_amount, 1);
        
        // Step 5: Simulate passage of time (finality delay)
        debug::print(&string::utf8(b"Step 5: Waiting for finality delay..."));
        timestamp::update_global_time_for_test_secs(current_time + 15);
        
        // Step 6: User withdraws from destination escrow using secret
        debug::print(&string::utf8(b"Step 6: User withdrawing from escrow with secret..."));
        
        // Calculate escrow address (would be provided by event in real implementation)
        let timelocks = timelock::new(10, 120, 121, 122, 10, 100, 101);
        let timelocks_with_time = timelock::with_deployed_at(timelocks, current_time);
        
        let token_type_string = string::utf8(b"0x200::mock_token::MockToken"); // Use the correct token type
        let immutables = escrow_core::new_immutables(
            order_hash,
            hashlock,
            maker_addr,
            taker_addr,
            token_type_string,
            token_amount,
            safety_deposit_amount,
            timelocks_with_time
        );
        
        let escrow_addr = escrow_factory::compute_dst_escrow_address(signer::address_of(admin), &immutables);
        
        debug::print(&string::utf8(b"Computed escrow address:"));
        debug::print(&escrow_addr);
        
        // User calls withdraw function
        resolver::withdraw<MockToken>(
            user,
            escrow_addr,
            secret,
            // immutables components (must match exactly)
            order_hash,
            hashlock,
            maker_addr,
            taker_addr,
            token_amount,
            safety_deposit_amount,
            // timelocks components
            10,   // src_withdrawal_delay
            120,  // src_public_withdrawal_delay
            121,  // src_cancellation_delay
            122,  // src_public_cancellation_delay
            10,   // dst_withdrawal_delay
            100,  // dst_public_withdrawal_delay
            101,  // dst_cancellation_delay
            current_time, // deployed_at
            signer::address_of(user) // recipient
        );
        
        // Step 7: Verify final balances
        debug::print(&string::utf8(b"Step 7: Verifying final balances..."));
        
        let final_user_balance = mock_token::balance(signer::address_of(user));
        let final_resolver_balance = mock_token::balance(signer::address_of(resolver));
        
        debug::print(&string::utf8(b"Final user balance:"));
        debug::print(&final_user_balance);
        debug::print(&string::utf8(b"Final resolver balance:"));
        debug::print(&final_resolver_balance);
        
        // Assertions
        assert!(final_user_balance == initial_user_balance + token_amount, 2);
        assert!(final_resolver_balance == initial_resolver_balance - token_amount, 3);
        
        debug::print(&string::utf8(b"SUCCESS: E2E Test Passed: Ethereum -> Aptos swap completed successfully!"));
    }
    
    /// Test error case: withdrawal with wrong secret
    #[test(framework = @aptos_framework, admin = @crosschain_escrow_factory, resolver = @resolver_addr, user = @0x456)]
    #[expected_failure(abort_code = 0x60002, location = crosschain_escrow_factory::escrow_core)]
    fun test_e2e_wrong_secret_failure(
        framework: &signer,
        admin: &signer,
        resolver: &signer,
        user: &signer
    ) {
        debug::print(&string::utf8(b"=== E2E Test: Wrong Secret Failure ==="));
        
        // Setup similar to successful test
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1700000000);
        
        setup_test(admin, resolver, user);
        
        escrow_factory::initialize<AptosCoin, MockToken>(
            admin, 3600, 7200, signer::address_of(admin), signer::address_of(admin)
        );
        resolver::initialize(resolver, signer::address_of(admin));
        
        // Create escrow
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, b"ethereum_order_hash_32_bytes_lo");
        
        let correct_secret = vector::empty<u8>();
        vector::append(&mut correct_secret, b"my_secret_password_for_swap_test");
        
        let hashlock = vector::empty<u8>();
        vector::append(&mut hashlock, b"my_secret_password_for_swap_test");
        
        let current_time = timestamp::now_seconds();
        
        resolver::deploy_dst_escrow<MockToken, AptosCoin, MockToken>(
            resolver,
            signer::address_of(resolver),
            10000, 1000,
            order_hash, hashlock,
            signer::address_of(user), signer::address_of(user),
            10000, 1000,
            10, 120, 121, 122, 10, 100, 101,
            current_time, current_time + 3600
        );
        
        timestamp::update_global_time_for_test_secs(current_time + 15);
        
        // Try to withdraw with wrong secret (should fail)
        let wrong_secret = vector::empty<u8>();
        vector::append(&mut wrong_secret, b"wrong_secret_will_fail_withdrawal");
        
        let timelocks = timelock::new(10, 120, 121, 122, 10, 100, 101);
        let timelocks_with_time = timelock::with_deployed_at(timelocks, current_time);
        let token_type_string = string::utf8(b"0x200::mock_token::MockToken");
        let immutables = escrow_core::new_immutables(
            order_hash, hashlock,
            signer::address_of(user), signer::address_of(user),
            token_type_string, 10000, 1000, timelocks_with_time
        );
        let escrow_addr = escrow_factory::compute_dst_escrow_address(signer::address_of(admin), &immutables);
        
        // This should fail with E_INVALID_SECRET
        resolver::withdraw<MockToken>(
            user, escrow_addr, wrong_secret,
            order_hash, hashlock,
            signer::address_of(user), signer::address_of(user),
            10000, 1000,
            10, 120, 121, 122, 10, 100, 101, current_time,
            signer::address_of(user)
        );
    }
}