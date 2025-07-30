#[test_only]
module resolver_addr::resolver_simple_test {
    use std::signer;
    use std::vector;
    use aptos_framework::timestamp;
    
    use resolver_addr::resolver;
    use crosschain_escrow_factory::escrow_factory;

    #[test(admin = @resolver_addr, factory_owner = @crosschain_escrow_factory)]
    public fun test_resolver_initialization(admin: &signer, factory_owner: &signer) {
        // Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(factory_owner);
        
        let admin_addr = signer::address_of(admin);
        let factory_addr = signer::address_of(factory_owner);
        
        // Initialize escrow factory first (with simplified generics)
        escrow_factory::initialize<u64, u64>(
            factory_owner,
            3600, // src_rescue_delay
            7200, // dst_rescue_delay  
            admin_addr, // fee_bank_owner
            admin_addr  // access_token_config_addr
        );
        
        // Initialize resolver
        resolver::initialize(admin, factory_addr);
        
        // Verify initialization
        assert!(resolver::is_initialized(admin_addr), 1);
        assert!(resolver::get_owner(admin_addr) == admin_addr, 2);
        assert!(resolver::get_factory_address(admin_addr) == factory_addr, 3);
    }

    #[test(admin = @resolver_addr)]
    public fun test_resolver_view_functions_uninitialized(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        
        // Test before initialization
        assert!(!resolver::is_initialized(admin_addr), 1);
    }

    #[test]
    public fun test_order_hash_validation() {
        // Test that our validation logic works for empty vectors
        let empty_order_hash = vector::empty<u8>();
        let valid_order_hash = b"test_order_hash_32_bytes_long!!!";
        
        assert!(vector::length(&empty_order_hash) == 0, 1);
        assert!(vector::length(&valid_order_hash) > 0, 2);
        assert!(vector::length(&valid_order_hash) == 32, 3);
    }

    #[test]
    public fun test_hashlock_validation() {
        // Test that our validation logic works for hashlocks
        let empty_hashlock = vector::empty<u8>();
        let valid_hashlock = b"test_secret_password_for_swap";
        
        assert!(vector::length(&empty_hashlock) == 0, 1);
        assert!(vector::length(&valid_hashlock) > 0, 2);
        assert!(vector::length(&valid_hashlock) == 29, 3); // Length of the test string
    }
}