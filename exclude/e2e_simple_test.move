#[test_only]
module crosschain_escrow_factory::e2e_simple_test {
    use std::signer;
    use aptos_std::debug;
    use std::string;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use token_addr::my_token::{Self, SimpleToken};
    use crosschain_escrow_factory::escrow_factory;
    use resolver_addr::resolver;

    #[test(admin = @crosschain_escrow_factory, resolver = @resolver_addr)]
    fun test_simple_factory_initialization(admin: &signer, resolver: &signer) {
        debug::print(&string::utf8(b"=== Simple E2E Test: Factory Initialization ==="));
        
        // Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(admin);
        
        // Initialize token system
        my_token::initialize(admin);
        coin::register<SimpleToken>(resolver);
        
        // Initialize factory
        escrow_factory::initialize<AptosCoin, SimpleToken>(
            admin,
            3600, // src_rescue_delay
            7200, // dst_rescue_delay  
            signer::address_of(admin), // fee_bank_owner
            signer::address_of(admin)  // access_token_config_addr
        );
        
        // Check factory initialization
        assert!(escrow_factory::is_factory_initialized<AptosCoin, SimpleToken>(signer::address_of(admin)), 1);
        
        // Initialize resolver
        resolver::initialize(resolver, signer::address_of(admin));
        
        // Check resolver initialization
        assert!(resolver::is_initialized(signer::address_of(resolver)), 2);
        
        debug::print(&string::utf8(b"SUCCESS: Factory and resolver initialized correctly!"));
    }
}