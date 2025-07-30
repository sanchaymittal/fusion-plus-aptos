/// Core escrow functionality for cross-chain atomic swaps
/// Handles basic escrow creation, withdrawal, cancellation, and hashlock validation
module crosschain_escrow_factory::escrow_core {
    use std::error;
    use std::hash;
    use std::signer;
    use std::vector;
    use std::string::String;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::timestamp;
    use aptos_std::type_info;
    
    use crosschain_escrow_factory::timelock::{Self, Timelocks};
    use crosschain_escrow_factory::create2;

    /// Error codes
    const E_INVALID_CALLER: u64 = 1;
    const E_INVALID_SECRET: u64 = 2;
    const E_INVALID_IMMUTABLES: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_ESCROW_NOT_FOUND: u64 = 5;
    const E_INVALID_AMOUNT: u64 = 6;
    const E_UNAUTHORIZED: u64 = 7;
    const E_ALREADY_EXISTS: u64 = 8;
    const E_INVALID_TIME: u64 = 9;

    /// Represents the immutable configuration of an escrow
    struct EscrowImmutables has copy, drop, store {
        order_hash: vector<u8>,
        hashlock: vector<u8>,  // Hash of the secret
        maker: address,
        taker: address,
        token_type: String,    // Type info for the token
        amount: u64,
        safety_deposit: u64,   // Native coin safety deposit
        timelocks: Timelocks,
    }

    /// Represents an active escrow instance
    struct Escrow<phantom TokenType> has key {
        immutables: EscrowImmutables,
        locked_tokens: Coin<TokenType>,
        safety_deposit: Coin<AptosCoin>,
        is_completed: bool,
        signer_cap: SignerCapability,
        
        // Events
        withdrawal_events: EventHandle<EscrowWithdrawalEvent>,
        cancellation_events: EventHandle<EscrowCancellationEvent>,
        rescue_events: EventHandle<FundsRescueEvent>,
    }

    /// Escrow metadata stored at factory level
    struct EscrowRegistry has key {
        escrows: vector<address>,
        escrow_count: u64,
    }

    // Events
    struct EscrowWithdrawalEvent has drop, store {
        escrow_address: address,
        secret: vector<u8>,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    struct EscrowCancellationEvent has drop, store {
        escrow_address: address,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    struct FundsRescueEvent has drop, store {
        escrow_address: address,
        token_type: String,
        amount: u64,
        recipient: address,
        timestamp: u64,
    }

    #[event]
    struct EscrowCreatedEvent has drop, store {
        escrow_address: address,
        immutables: EscrowImmutables,
        is_source: bool,
        timestamp: u64,
    }

    /// Initialize the escrow system
    public entry fun initialize(account: &signer) {
        let account_addr = signer::address_of(account);
        if (!exists<EscrowRegistry>(account_addr)) {
            move_to(account, EscrowRegistry {
                escrows: vector::empty(),
                escrow_count: 0,
            });
        };
    }

    /// Creates a new escrow immutables configuration
    public fun new_immutables(
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: address,
        taker: address,
        token_type: String,
        amount: u64,
        safety_deposit: u64,
        timelocks: Timelocks,
    ): EscrowImmutables {
        EscrowImmutables {
            order_hash,
            hashlock,
            maker,
            taker,
            token_type,
            amount,
            safety_deposit,
            timelocks,
        }
    }

    /// Computes the hash of escrow immutables (used for deterministic addressing)
    public fun hash_immutables(immutables: &EscrowImmutables): vector<u8> {
        let data = vector::empty<u8>();
        vector::append(&mut data, immutables.order_hash);
        vector::append(&mut data, immutables.hashlock);
        vector::append(&mut data, std::bcs::to_bytes(&immutables.maker));
        vector::append(&mut data, std::bcs::to_bytes(&immutables.taker));
        vector::append(&mut data, std::bcs::to_bytes(&immutables.token_type));
        vector::append(&mut data, std::bcs::to_bytes(&immutables.amount));
        vector::append(&mut data, std::bcs::to_bytes(&immutables.safety_deposit));
        vector::append(&mut data, std::bcs::to_bytes(&immutables.timelocks));
        
        hash::sha3_256(data)
    }

    /// Creates a new escrow instance
    public fun create_escrow<TokenType>(
        factory: &signer,
        immutables: EscrowImmutables,
        locked_tokens: Coin<TokenType>,
        safety_deposit: Coin<AptosCoin>,
        is_source: bool,
    ): address acquires EscrowRegistry {
        let factory_addr = signer::address_of(factory);
        
        // Generate deterministic address
        let immutables_hash = hash_immutables(&immutables);
        let salt = create2::generate_salt_from_immutables_hash(immutables_hash);
        let implementation_type = if (is_source) {
            create2::implementation_src()
        } else {
            create2::implementation_dst()
        };
        
        let escrow_addr = create2::create_resource_address(
            factory_addr,
            salt,
            implementation_type
        );

        // Create resource account for the escrow
        let (escrow_signer, signer_cap) = account::create_resource_account(factory, salt);
        let escrow_address = signer::address_of(&escrow_signer);

        // Validate amounts
        assert!(coin::value(&locked_tokens) >= immutables.amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));
        assert!(coin::value(&safety_deposit) >= immutables.safety_deposit, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Set deployment timestamp
        let updated_immutables = immutables;
        timelock::set_deployed_at(&mut updated_immutables.timelocks, timestamp::now_seconds());

        // Create escrow instance
        let escrow = Escrow<TokenType> {
            immutables: updated_immutables,
            locked_tokens,
            safety_deposit,
            is_completed: false,
            signer_cap,
            withdrawal_events: account::new_event_handle(&escrow_signer),
            cancellation_events: account::new_event_handle(&escrow_signer),
            rescue_events: account::new_event_handle(&escrow_signer),
        };

        move_to(&escrow_signer, escrow);

        // Register in factory
        if (!exists<EscrowRegistry>(factory_addr)) {
            initialize(factory);
        };
        
        let registry = borrow_global_mut<EscrowRegistry>(factory_addr);
        vector::push_back(&mut registry.escrows, escrow_address);
        registry.escrow_count = registry.escrow_count + 1;

        // Emit creation event
        event::emit(EscrowCreatedEvent {
            escrow_address,
            immutables: updated_immutables,
            is_source,
            timestamp: timestamp::now_seconds(),
        });

        escrow_address
    }

    /// Validates that the provided immutables match the escrow
    public fun validate_immutables<TokenType>(
        escrow_addr: address,
        provided_immutables: &EscrowImmutables,
        factory_addr: address,
        is_source: bool,
    ): bool acquires Escrow {
        if (!exists<Escrow<TokenType>>(escrow_addr)) {
            return false
        };

        let escrow = borrow_global<Escrow<TokenType>>(escrow_addr);
        
        // Verify immutables match
        if (escrow.immutables != *provided_immutables) {
            return false
        };

        // Verify deterministic address generation
        let immutables_hash = hash_immutables(provided_immutables);
        let implementation_type = if (is_source) {
            create2::implementation_src()
        } else {
            create2::implementation_dst()
        };

        create2::verify_address_generation(
            escrow_addr,
            factory_addr,
            immutables_hash,
            implementation_type
        )
    }

    /// Validates that the provided secret matches the hashlock
    public fun validate_secret(secret: vector<u8>, hashlock: vector<u8>): bool {
        let secret_hash = hash::sha3_256(secret);
        secret_hash == hashlock
    }

    /// Withdraws funds from escrow (basic implementation)
    public fun withdraw<TokenType>(
        caller: &signer,
        escrow_addr: address,
        secret: vector<u8>,
        immutables: EscrowImmutables,
        recipient: address,
    ) acquires Escrow {
        let caller_addr = signer::address_of(caller);
        assert!(exists<Escrow<TokenType>>(escrow_addr), error::not_found(E_ESCROW_NOT_FOUND));
        
        let escrow = borrow_global_mut<Escrow<TokenType>>(escrow_addr);
        
        // Validate caller is taker
        assert!(caller_addr == escrow.immutables.taker, error::permission_denied(E_UNAUTHORIZED));
        
        // Validate immutables
        assert!(escrow.immutables == immutables, error::invalid_argument(E_INVALID_IMMUTABLES));
        
        // Validate secret
        assert!(validate_secret(secret, escrow.immutables.hashlock), error::invalid_argument(E_INVALID_SECRET));
        
        // Validate not already completed
        assert!(!escrow.is_completed, error::invalid_state(E_INVALID_TIME));

        // Transfer tokens to recipient
        let tokens = coin::extract_all(&mut escrow.locked_tokens);
        coin::deposit(recipient, tokens);

        // Transfer safety deposit to caller
        let deposit = coin::extract_all(&mut escrow.safety_deposit);
        coin::deposit(caller_addr, deposit);

        escrow.is_completed = true;

        // Emit withdrawal event
        event::emit_event(&mut escrow.withdrawal_events, EscrowWithdrawalEvent {
            escrow_address: escrow_addr,
            secret,
            recipient,
            amount: immutables.amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Cancels escrow and returns funds to maker
    public fun cancel<TokenType>(
        caller: &signer,
        escrow_addr: address,
        immutables: EscrowImmutables,
    ) acquires Escrow {
        let caller_addr = signer::address_of(caller);
        assert!(exists<Escrow<TokenType>>(escrow_addr), error::not_found(E_ESCROW_NOT_FOUND));
        
        let escrow = borrow_global_mut<Escrow<TokenType>>(escrow_addr);
        
        // Validate caller is taker
        assert!(caller_addr == escrow.immutables.taker, error::permission_denied(E_UNAUTHORIZED));
        
        // Validate immutables
        assert!(escrow.immutables == immutables, error::invalid_argument(E_INVALID_IMMUTABLES));
        
        // Validate not already completed
        assert!(!escrow.is_completed, error::invalid_state(E_INVALID_TIME));

        // Transfer tokens back to maker
        let tokens = coin::extract_all(&mut escrow.locked_tokens);
        coin::deposit(escrow.immutables.maker, tokens);

        // Transfer safety deposit to caller
        let deposit = coin::extract_all(&mut escrow.safety_deposit);
        coin::deposit(caller_addr, deposit);

        escrow.is_completed = true;

        // Emit cancellation event
        event::emit_event(&mut escrow.cancellation_events, EscrowCancellationEvent {
            escrow_address: escrow_addr,
            recipient: escrow.immutables.maker,
            amount: immutables.amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Emergency rescue funds (after rescue delay)
    public fun rescue_funds<TokenType, RescueTokenType>(
        caller: &signer,
        escrow_addr: address,
        amount: u64,
        rescue_delay: u64,
        immutables: EscrowImmutables,
    ) acquires Escrow {
        let caller_addr = signer::address_of(caller);
        assert!(exists<Escrow<TokenType>>(escrow_addr), error::not_found(E_ESCROW_NOT_FOUND));
        
        let escrow = borrow_global_mut<Escrow<TokenType>>(escrow_addr);
        
        // Validate caller is taker
        assert!(caller_addr == escrow.immutables.taker, error::permission_denied(E_UNAUTHORIZED));
        
        // Validate immutables
        assert!(escrow.immutables == immutables, error::invalid_argument(E_INVALID_IMMUTABLES));
        
        // Validate rescue time has passed
        assert!(timelock::is_rescue_time(&escrow.immutables.timelocks, rescue_delay), 
                error::invalid_state(E_INVALID_TIME));

        // For now, we'll implement basic rescue for the locked token type
        // In a full implementation, this would handle arbitrary token types
        if (type_info::type_name<RescueTokenType>() == type_info::type_name<TokenType>()) {
            let available_amount = coin::value(&escrow.locked_tokens);
            let rescue_amount = if (amount > available_amount) available_amount else amount;
            
            if (rescue_amount > 0) {
                let rescued_coins = coin::extract(&mut escrow.locked_tokens, rescue_amount);
                coin::deposit(caller_addr, rescued_coins);
            };
        };

        // Emit rescue event
        event::emit_event(&mut escrow.rescue_events, FundsRescueEvent {
            escrow_address: escrow_addr,
            token_type: type_info::type_name<RescueTokenType>(),
            amount,
            recipient: caller_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    // View functions
    public fun get_escrow_immutables<TokenType>(escrow_addr: address): EscrowImmutables acquires Escrow {
        let escrow = borrow_global<Escrow<TokenType>>(escrow_addr);
        escrow.immutables
    }

    public fun is_escrow_completed<TokenType>(escrow_addr: address): bool acquires Escrow {
        let escrow = borrow_global<Escrow<TokenType>>(escrow_addr);
        escrow.is_completed
    }

    public fun get_locked_amount<TokenType>(escrow_addr: address): u64 acquires Escrow {
        let escrow = borrow_global<Escrow<TokenType>>(escrow_addr);
        coin::value(&escrow.locked_tokens)
    }

    public fun get_safety_deposit<TokenType>(escrow_addr: address): u64 acquires Escrow {
        let escrow = borrow_global<Escrow<TokenType>>(escrow_addr);
        coin::value(&escrow.safety_deposit)
    }

    public fun escrow_exists<TokenType>(escrow_addr: address): bool {
        exists<Escrow<TokenType>>(escrow_addr)
    }

    public fun get_escrow_count(factory_addr: address): u64 acquires EscrowRegistry {
        if (!exists<EscrowRegistry>(factory_addr)) {
            0
        } else {
            let registry = borrow_global<EscrowRegistry>(factory_addr);
            registry.escrow_count
        }
    }

    public fun get_all_escrows(factory_addr: address): vector<address> acquires EscrowRegistry {
        if (!exists<EscrowRegistry>(factory_addr)) {
            vector::empty()
        } else {
            let registry = borrow_global<EscrowRegistry>(factory_addr);
            registry.escrows
        }
    }

    // Getters for EscrowImmutables
    public fun get_order_hash(immutables: &EscrowImmutables): vector<u8> { 
        // Ensure order_hash is not empty
        assert!(vector::length(&immutables.order_hash) > 0, error::invalid_argument(E_INVALID_IMMUTABLES));
        immutables.order_hash 
    }
    public fun get_hashlock(immutables: &EscrowImmutables): vector<u8> { 
        // Ensure hashlock is not empty
        assert!(vector::length(&immutables.hashlock) > 0, error::invalid_argument(E_INVALID_IMMUTABLES));
        immutables.hashlock 
    }
    public fun get_maker(immutables: &EscrowImmutables): address { immutables.maker }
    public fun get_taker(immutables: &EscrowImmutables): address { immutables.taker }
    public fun get_token_type(immutables: &EscrowImmutables): String { 
        // Ensure token_type is not empty
        assert!(std::string::length(&immutables.token_type) > 0, error::invalid_argument(E_INVALID_IMMUTABLES));
        immutables.token_type 
    }
    public fun get_amount(immutables: &EscrowImmutables): u64 { immutables.amount }
    public fun get_safety_deposit_amount(immutables: &EscrowImmutables): u64 { immutables.safety_deposit }
    public fun get_timelocks(immutables: &EscrowImmutables): Timelocks { immutables.timelocks }
}