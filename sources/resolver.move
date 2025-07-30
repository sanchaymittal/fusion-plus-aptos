/// Resolver contract for cross-chain atomic swap operations
/// Provides entry functions to interact with the escrow factory
module resolver_addr::resolver {
    use std::signer;
    use std::vector;
    use std::option;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    
    use crosschain_escrow_factory::escrow_factory::{Self, SrcEscrowArgs, OrderData};
    use crosschain_escrow_factory::escrow_core::{Self, EscrowImmutables};
    use crosschain_escrow_factory::timelock::{Self, Timelocks};
    use std::string::{Self, String};
    use aptos_std::type_info;

    /// Error codes
    const E_UNAUTHORIZED: u64 = 1;

    /// Resolver configuration
    struct ResolverConfig has key {
        owner: address,
        factory_address: address,
    }

    /// Initialize the resolver
    public entry fun initialize(
        admin: &signer,
        factory_address: address,
    ) {
        let admin_addr = signer::address_of(admin);
        
        move_to(admin, ResolverConfig {
            owner: admin_addr,
            factory_address,
        });
    }

    /// Creates a destination escrow via the factory (new version without token_type parameter)
    public entry fun deploy_dst_escrow<TokenType, FeeTokenType, AccessTokenType>(
        caller: &signer,
        resolver_addr: address,
        token_amount: u64,
        safety_deposit_amount: u64,
        // immutables components
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: address,
        taker: address,
        amount: u64,
        safety_deposit: u64,
        // timelocks components
        src_withdrawal_delay: u64,
        src_public_withdrawal_delay: u64,
        src_cancellation_delay: u64,
        src_public_cancellation_delay: u64,
        dst_withdrawal_delay: u64,
        dst_public_withdrawal_delay: u64,
        dst_cancellation_delay: u64,
        deployed_at: u64,
        src_cancellation_timestamp: u64,
    ) acquires ResolverConfig {
        let caller_addr = signer::address_of(caller);
        let config = borrow_global<ResolverConfig>(resolver_addr);
        
        // Only owner can call this function
        assert!(caller_addr == config.owner, E_UNAUTHORIZED);

        // Withdraw the required tokens from caller's account
        let tokens = coin::withdraw<TokenType>(caller, token_amount);
        let safety_deposit_coins = coin::withdraw<AptosCoin>(caller, safety_deposit_amount);

        // Reconstruct timelocks
        let timelocks = timelock::new(
            (src_withdrawal_delay as u32),
            (src_public_withdrawal_delay as u32),
            (src_cancellation_delay as u32),
            (src_public_cancellation_delay as u32),
            (dst_withdrawal_delay as u32),
            (dst_public_withdrawal_delay as u32),
            (dst_cancellation_delay as u32)
        );
        let timelocks = timelock::with_deployed_at(timelocks, deployed_at);

        // Reconstruct immutables
        // Derive token type programmatically from the generic type parameter
        let token_type_string = type_info::type_name<TokenType>();
        
        // Validate order_hash is not empty
        assert!(vector::length(&order_hash) > 0, E_UNAUTHORIZED);
        assert!(vector::length(&hashlock) > 0, E_UNAUTHORIZED);
        
        let immutables = escrow_core::new_immutables(
            order_hash,
            hashlock,
            maker,
            taker,
            token_type_string,
            amount,
            safety_deposit,
            timelocks
        );

        // Create destination escrow args
        let args = escrow_factory::new_dst_escrow_args(
            immutables,
            src_cancellation_timestamp
        );

        // Call the factory to create the destination escrow
        let (_, remaining_tokens, remaining_deposit) = 
            escrow_factory::create_dst_escrow<TokenType, FeeTokenType, AccessTokenType>(
                caller,
                config.factory_address,
                tokens,
                safety_deposit_coins,
                args
            );

        // Return any remaining tokens and deposits to the caller
        if (coin::value(&remaining_tokens) > 0) {
            coin::deposit(caller_addr, remaining_tokens);
        } else {
            coin::destroy_zero(remaining_tokens);
        };

        if (coin::value(&remaining_deposit) > 0) {
            coin::deposit(caller_addr, remaining_deposit);
        } else {
            coin::destroy_zero(remaining_deposit);
        };
    }

    // Note: deploy_src_escrow would need similar treatment but is complex due to SrcEscrowArgs
    // For now, keeping it as a non-entry function that can be called from other contracts

    /// Withdraws from an escrow via escrow_core (new version without token_type parameter)
    public entry fun withdraw<TokenType>(
        caller: &signer,
        escrow_addr: address,
        secret: vector<u8>,
        // immutables components
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: address,
        taker: address,
        amount: u64,
        safety_deposit: u64,
        // timelocks components
        src_withdrawal_delay: u64,
        src_public_withdrawal_delay: u64,
        src_cancellation_delay: u64,
        src_public_cancellation_delay: u64,
        dst_withdrawal_delay: u64,
        dst_public_withdrawal_delay: u64,
        dst_cancellation_delay: u64,
        deployed_at: u64,
        recipient: address,
    ) {
        // Reconstruct timelocks
        let timelocks = timelock::new(
            (src_withdrawal_delay as u32),
            (src_public_withdrawal_delay as u32),
            (src_cancellation_delay as u32),
            (src_public_cancellation_delay as u32),
            (dst_withdrawal_delay as u32),
            (dst_public_withdrawal_delay as u32),
            (dst_cancellation_delay as u32)
        );
        let timelocks = timelock::with_deployed_at(timelocks, deployed_at);

        // Reconstruct immutables
        let token_type_string = type_info::type_name<TokenType>();
        
        let immutables = escrow_core::new_immutables(
            order_hash,
            hashlock,
            maker,
            taker,
            token_type_string,
            amount,
            safety_deposit,
            timelocks
        );

        escrow_core::withdraw<TokenType>(
            caller,
            escrow_addr,
            secret,
            immutables,
            recipient
        );
    }

    /// Cancels an escrow via escrow_core (new version without token_type parameter)
    public entry fun cancel<TokenType>(
        caller: &signer,
        escrow_addr: address,
        // immutables components
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: address,
        taker: address,
        amount: u64,
        safety_deposit: u64,
        // timelocks components
        src_withdrawal_delay: u64,
        src_public_withdrawal_delay: u64,
        src_cancellation_delay: u64,
        src_public_cancellation_delay: u64,
        dst_withdrawal_delay: u64,
        dst_public_withdrawal_delay: u64,
        dst_cancellation_delay: u64,
        deployed_at: u64,
    ) {
        // Reconstruct timelocks
        let timelocks = timelock::new(
            (src_withdrawal_delay as u32),
            (src_public_withdrawal_delay as u32),
            (src_cancellation_delay as u32),
            (src_public_cancellation_delay as u32),
            (dst_withdrawal_delay as u32),
            (dst_public_withdrawal_delay as u32),
            (dst_cancellation_delay as u32)
        );
        let timelocks = timelock::with_deployed_at(timelocks, deployed_at);

        // Reconstruct immutables
        let token_type_string = type_info::type_name<TokenType>();
        
        let immutables = escrow_core::new_immutables(
            order_hash,
            hashlock,
            maker,
            taker,
            token_type_string,
            amount,
            safety_deposit,
            timelocks
        );

        escrow_core::cancel<TokenType>(
            caller,
            escrow_addr,
            immutables
        );
    }

    // View functions
    public fun get_owner(resolver_addr: address): address acquires ResolverConfig {
        borrow_global<ResolverConfig>(resolver_addr).owner
    }

    public fun get_factory_address(resolver_addr: address): address acquires ResolverConfig {
        borrow_global<ResolverConfig>(resolver_addr).factory_address
    }

    public fun is_initialized(resolver_addr: address): bool {
        exists<ResolverConfig>(resolver_addr)
    }
}