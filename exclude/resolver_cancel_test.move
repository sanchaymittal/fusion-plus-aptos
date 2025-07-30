#[test_only]
module resolver_addr::resolver_cancel_test {
    use std::signer;
    use std::vector;
    use aptos_std::debug;
    use aptos_framework::timestamp;
    
    use token_addr::my_token::SimpleToken;
    use aptos_framework::aptos_coin::AptosCoin;
    use resolver_addr::resolver;
    use crosschain_escrow_factory::escrow_factory;

    #[test(admin = @resolver_addr, factory_owner = @crosschain_escrow_factory)]
    public fun test_cancel_function_with_transaction_params(admin: &signer, factory_owner: &signer) {
        // Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(factory_owner);
        
        let admin_addr = signer::address_of(admin);
        let factory_addr = signer::address_of(factory_owner);
        
        // Initialize escrow factory first
        escrow_factory::initialize<u64, u64>(
            factory_owner,
            3600, // src_rescue_delay
            7200, // dst_rescue_delay  
            admin_addr, // fee_bank_owner
            admin_addr  // access_token_config_addr
        );
        
        // Initialize resolver
        resolver::initialize(admin, factory_addr);
        
        debug::print(&b"Resolver initialized successfully");
        
        // Use parameters similar to the failed transaction
        let escrow_addr = @0xb99c15a2260306d00e120f07df53225df91051e7632ce71b3dda998bdbf1aee7;
        
        // Create order_hash from the transaction
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, x"99c3686245c66cba8e6699f249c80649355b9cd16e42f83ac9dff4419421332c");
        
        // Create hashlock from the transaction 
        let hashlock = vector::empty<u8>();
        vector::append(&mut hashlock, x"6d795f7365637265745f70617373776f72645f666f725f737761705f74657374");
        
        let maker = @0xb99c15a2260306d00e120f07df53225df91051e7632ce71b3dda998bdbf1aee7;
        let taker = @0xb99c15a2260306d00e120f07df53225df91051e7632ce71b3dda998bdbf1aee7;
        
        // Token type as bytes (from transaction)
        let token_type = vector::empty<u8>();
        let token_type_str = b"0xb99c15a2260306d00e120f07df53225df91051e7632ce71b3dda998bdbf1aee7::my_token::SimpleToken";
        vector::append(&mut token_type, token_type_str);
        
        let amount = 10000;
        let safety_deposit = 1000;
        
        // Timelocks from the transaction
        let src_withdrawal_delay = 10;
        let src_public_withdrawal_delay = 120;
        let src_cancellation_delay = 121;
        let src_public_cancellation_delay = 122;
        let dst_withdrawal_delay = 10;
        let dst_public_withdrawal_delay = 100;
        let dst_cancellation_delay = 101;
        let deployed_at = 1753853633;
        
        debug::print(&b"About to call cancel function with transaction parameters");
        
        // This should reproduce the error from the transaction
        resolver::cancel<SimpleToken>(
            admin,
            escrow_addr,
            order_hash,
            hashlock,
            maker,
            taker,
            token_type,
            amount,
            safety_deposit,
            src_withdrawal_delay,
            src_public_withdrawal_delay,
            src_cancellation_delay,
            src_public_cancellation_delay,
            dst_withdrawal_delay,
            dst_public_withdrawal_delay,
            dst_cancellation_delay,
            deployed_at,
        );
        
        debug::print(&b"Cancel function completed successfully");
    }

    #[test(admin = @resolver_addr)]
    public fun test_cancel_parameter_validation(admin: &signer) {
        // Initialize resolver with minimal setup
        let factory_address = signer::address_of(admin);
        resolver::initialize(admin, factory_address);
        
        debug::print(&b"Testing parameter validation for cancel function");
        
        // Test with minimal parameters to isolate the validation issue
        let escrow_addr = @0x1;
        
        // Test with empty vectors to see if validation catches them
        let empty_order_hash = vector::empty<u8>();
        let empty_hashlock = vector::empty<u8>();
        
        let maker = signer::address_of(admin);
        let taker = signer::address_of(admin);
        let token_type = b"test_token_type";
        let amount = 0; // Test with zero amount
        let safety_deposit = 0; // Test with zero safety deposit
        
        // Basic timelocks
        let src_withdrawal_delay = 0;
        let src_public_withdrawal_delay = 0;
        let src_cancellation_delay = 0;
        let src_public_cancellation_delay = 0;
        let dst_withdrawal_delay = 0;
        let dst_public_withdrawal_delay = 0;
        let dst_cancellation_delay = 0;
        let deployed_at = 0;
        
        debug::print(&b"Testing cancel with minimal parameters");
        
        // This should help us identify which parameter validation is failing
        resolver::cancel<SimpleToken>(
            admin,
            escrow_addr,
            empty_order_hash,
            empty_hashlock,
            maker,
            taker,
            token_type,
            amount,
            safety_deposit,
            src_withdrawal_delay,
            src_public_withdrawal_delay,
            src_cancellation_delay,
            src_public_cancellation_delay,
            dst_withdrawal_delay,
            dst_public_withdrawal_delay,
            dst_cancellation_delay,
            deployed_at,
        );
        
        debug::print(&b"Parameter validation test completed");
    }

    #[test(admin = @resolver_addr)]
    public fun test_cancel_with_valid_minimal_params(admin: &signer) {
        // Initialize resolver
        let factory_address = signer::address_of(admin);
        resolver::initialize(admin, factory_address);
        
        debug::print(&b"Testing cancel with valid minimal parameters");
        
        let escrow_addr = @0x1;
        
        // Use valid non-empty parameters
        let order_hash = b"test_order_hash_32_bytes_long!!!";
        let hashlock = b"test_secret_password_for_swap_test";
        
        let maker = signer::address_of(admin);
        let taker = signer::address_of(admin);
        let token_type = b"test_token_type";
        let amount = 100; // Non-zero valid amount
        let safety_deposit = 10; // Non-zero valid safety deposit
        
        // Valid timelocks
        let src_withdrawal_delay = 10;
        let src_public_withdrawal_delay = 120;
        let src_cancellation_delay = 121;
        let src_public_cancellation_delay = 122;
        let dst_withdrawal_delay = 10;
        let dst_public_withdrawal_delay = 100;
        let dst_cancellation_delay = 101;
        let deployed_at = 1000000; // Valid timestamp
        
        debug::print(&b"Calling cancel with valid minimal parameters");
        
        resolver::cancel<SimpleToken>(
            admin,
            escrow_addr,
            order_hash,
            hashlock,
            maker,
            taker,
            token_type,
            amount,
            safety_deposit,
            src_withdrawal_delay,
            src_public_withdrawal_delay,
            src_cancellation_delay,
            src_public_cancellation_delay,
            dst_withdrawal_delay,
            dst_public_withdrawal_delay,
            dst_cancellation_delay,
            deployed_at,
        );
        
        debug::print(&b"Cancel with valid minimal parameters completed");
    }
}