#[test_only]
module crosschain_escrow_factory::resolver_test {
    use std::signer;
    use std::vector;
    use aptos_std::debug;
    use aptos_std::type_info;
    
    use token_addr::my_token::SimpleToken;
    use aptos_framework::aptos_coin::AptosCoin;
    use resolver_addr::resolver;

    #[test(admin = @0x123)]
    fun test_resolver_initialization(admin: &signer) {
        let factory_address = @0x456;
        
        // Test resolver initialization
        resolver::initialize(admin, factory_address);
        
        // Verify initialization
        assert!(resolver::is_initialized(signer::address_of(admin)), 1);
        assert!(resolver::get_factory_address(signer::address_of(admin)) == factory_address, 2);
        assert!(resolver::get_owner(signer::address_of(admin)) == signer::address_of(admin), 3);
    }

    #[test(admin = @0x123)]
    fun test_debug_deploy_escrow_fresh_basic(admin: &signer) {
        // Initialize resolver
        let factory_address = signer::address_of(admin); // Use same address as factory for testing
        resolver::initialize(admin, factory_address);
        
        // Prepare test parameters similar to the TypeScript test
        let resolver_addr = signer::address_of(admin);
        let token_amount = 10000;
        let safety_deposit_amount = 1000;
        
        // Create test immutables components
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, b"test_order_hash_32_bytes_long!!");
        
        let hashlock = vector::empty<u8>();
        vector::append(&mut hashlock, b"my_secret_password_for_swap_test");
        
        let maker = signer::address_of(admin);
        let taker = signer::address_of(admin);
        
        // Token type as bytes (this is what was causing issues)
        let token_type = vector::empty<u8>();
        let token_type_str = b"0x123::my_token::SimpleToken";
        vector::append(&mut token_type, token_type_str);
        
        let amount = 10000;
        let safety_deposit = 1000;
        
        // Timelocks components
        let src_withdrawal_delay = 10;
        let src_public_withdrawal_delay = 120;
        let src_cancellation_delay = 121;
        let src_public_cancellation_delay = 122;
        let dst_withdrawal_delay = 10;
        let dst_public_withdrawal_delay = 100;
        let dst_cancellation_delay = 101;
        let deployed_at = 1753853633;
        let src_cancellation_timestamp = 1753857233;
        
        debug::print(&b"About to call debug_deploy_escrow_fresh");
        
        // This should work without any errors if our fix is correct
        resolver::debug_deploy_escrow_fresh<SimpleToken, AptosCoin, SimpleToken>(
            admin,
            resolver_addr,
            token_amount,
            safety_deposit_amount,
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
            src_cancellation_timestamp,
        );
        
        debug::print(&b"debug_deploy_escrow_fresh completed successfully");
    }

    #[test]
    fun test_type_info_directly() {
        // Test type_info::type_name directly to make sure it works
        let token_type_string = type_info::type_name<SimpleToken>();
        debug::print(&b"Token type string:");
        debug::print(&token_type_string);
        
        // Test with different types
        let apt_type_string = type_info::type_name<AptosCoin>();
        debug::print(&b"APT type string:");
        debug::print(&apt_type_string);
    }

    #[test(admin = @0x123)]
    fun test_deploy_dst_escrow_original(admin: &signer) {
        // Initialize resolver
        let factory_address = signer::address_of(admin);
        resolver::initialize(admin, factory_address);
        
        // Same parameters as the fresh function test
        let resolver_addr = signer::address_of(admin);
        let token_amount = 10000;
        let safety_deposit_amount = 1000;
        
        let order_hash = vector::empty<u8>();
        vector::append(&mut order_hash, b"test_order_hash_32_bytes_long!!");
        
        let hashlock = vector::empty<u8>();
        vector::append(&mut hashlock, b"my_secret_password_for_swap_test");
        
        let maker = signer::address_of(admin);
        let taker = signer::address_of(admin);
        
        let token_type = vector::empty<u8>();
        let token_type_str = b"0x123::my_token::SimpleToken";
        vector::append(&mut token_type, token_type_str);
        
        let amount = 10000;
        let safety_deposit = 1000;
        
        let src_withdrawal_delay = 10;
        let src_public_withdrawal_delay = 120;
        let src_cancellation_delay = 121;
        let src_public_cancellation_delay = 122;
        let dst_withdrawal_delay = 10;
        let dst_public_withdrawal_delay = 100;
        let dst_cancellation_delay = 101;
        let deployed_at = 1753853633;
        let src_cancellation_timestamp = 1753857233;
        
        debug::print(&b"About to call original deploy_dst_escrow");
        
        // Test the original function that was having issues
        resolver::deploy_dst_escrow<SimpleToken, AptosCoin, SimpleToken>(
            admin,
            resolver_addr,
            token_amount,
            safety_deposit_amount,
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
            src_cancellation_timestamp,
        );
        
        debug::print(&b"Original deploy_dst_escrow completed successfully");
    }
}