/// Merkle proof validation module for supporting multiple fills with different secrets
/// Handles Merkle tree validation, secret management for partial fills
module crosschain_escrow_factory::merkle_validator {
    use std::error;
    use std::hash;
    use std::vector;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;

    /// Error codes
    const E_INVALID_PROOF: u64 = 1;
    const E_INVALID_INDEX: u64 = 2;
    const E_INVALID_SECRET: u64 = 3;
    const E_ROOT_MISMATCH: u64 = 4;
    const E_ALREADY_VALIDATED: u64 = 5;
    const E_INVALID_FILL_DATA: u64 = 6;

    /// Validation data for tracking last validated secret
    struct ValidationData has copy, drop, store {
        index: u64,        // Index of the last validated secret
        secret_hash: vector<u8>, // Last validated secret hash (leaf)
    }

    /// Taker data for Merkle proof validation
    struct TakerData has copy, drop {
        proof: vector<vector<u8>>, // Merkle proof path
        idx: u64,                  // Index in the Merkle tree
        secret_hash: vector<u8>,   // Hash of the secret
    }

    /// Storage for validation tracking
    struct MerkleStorage has key {
        // Maps order_hash + root_shortened -> ValidationData
        validations: vector<ValidationEntry>,
        validation_events: EventHandle<SecretValidationEvent>,
    }

    /// Entry in the validation storage
    struct ValidationEntry has store {
        key: vector<u8>,           // order_hash + root_shortened
        validation_data: ValidationData,
    }

    /// Event emitted when a secret is validated
    struct SecretValidationEvent has drop, store {
        order_hash: vector<u8>,
        root_shortened: vector<u8>,
        index: u64,
        secret_hash: vector<u8>,
        timestamp: u64,
    }

    /// Multiple fill configuration
    struct MultipleFillConfig has copy, drop, store {
        root_hash: vector<u8>,     // Full Merkle root
        parts_amount: u64,         // Number of parts the order can be split into
        root_shortened: vector<u8>, // First 30 bytes of root (240 bits)
    }

    /// Initialize Merkle storage for an account
    public entry fun initialize(account: &signer) {
        let account_addr = std::signer::address_of(account);
        if (!exists<MerkleStorage>(account_addr)) {
            move_to(account, MerkleStorage {
                validations: vector::empty(),
                validation_events: account::new_event_handle(account),
            });
        };
    }

    /// Creates a new multiple fill configuration
    public fun new_multiple_fill_config(
        root_hash: vector<u8>,
        parts_amount: u64
    ): MultipleFillConfig {
        assert!(parts_amount >= 2, error::invalid_argument(E_INVALID_FILL_DATA));
        assert!(vector::length(&root_hash) == 32, error::invalid_argument(E_INVALID_PROOF));
        
        // Extract first 30 bytes (240 bits) for shortened root
        let root_shortened = vector::empty<u8>();
        let i = 0;
        while (i < 30) {
            vector::push_back(&mut root_shortened, *vector::borrow(&root_hash, i));
            i = i + 1;
        };

        MultipleFillConfig {
            root_hash,
            parts_amount,
            root_shortened,
        }
    }

    /// Creates taker data for proof validation
    public fun new_taker_data(
        proof: vector<vector<u8>>,
        idx: u64,
        secret_hash: vector<u8>
    ): TakerData {
        TakerData {
            proof,
            idx,
            secret_hash,
        }
    }

    /// Validates a Merkle proof and stores the validation data
    public fun validate_and_store_proof(
        validator: &signer,
        order_hash: vector<u8>,
        config: &MultipleFillConfig,
        taker_data: &TakerData,
    ) acquires MerkleStorage {
        let validator_addr = std::signer::address_of(validator);
        
        // Ensure storage is initialized
        if (!exists<MerkleStorage>(validator_addr)) {
            initialize(validator);
        };

        // Calculate leaf from index and secret hash
        let leaf = calculate_leaf(taker_data.idx, &taker_data.secret_hash);
        
        // Verify Merkle proof
        let calculated_root = process_proof(&taker_data.proof, leaf);
        assert!(calculated_root == config.root_hash, error::invalid_argument(E_INVALID_PROOF));

        // Extract shortened root from calculated root for key generation
        let calculated_shortened = vector::empty<u8>();
        let i = 0;
        while (i < 30) {
            vector::push_back(&mut calculated_shortened, *vector::borrow(&calculated_root, i));
            i = i + 1;
        };
        
        // Verify shortened roots match
        assert!(calculated_shortened == config.root_shortened, error::invalid_argument(E_ROOT_MISMATCH));

        // Generate storage key
        let key = generate_validation_key(&order_hash, &config.root_shortened);
        
        // Create validation data
        let validation_data = ValidationData {
            index: taker_data.idx + 1, // Store next expected index
            secret_hash: taker_data.secret_hash,
        };

        // Store validation
        let storage = borrow_global_mut<MerkleStorage>(validator_addr);
        store_validation(storage, key, validation_data);

        // Emit event
        event::emit_event(&mut storage.validation_events, SecretValidationEvent {
            order_hash,
            root_shortened: config.root_shortened,
            index: taker_data.idx,
            secret_hash: taker_data.secret_hash,
            timestamp: aptos_framework::timestamp::now_seconds(),
        });
    }

    /// Processes a Merkle proof to calculate root
    public fun process_proof(proof: &vector<vector<u8>>, leaf: vector<u8>): vector<u8> {
        let computed_hash = leaf;
        let proof_length = vector::length(proof);
        let i = 0;
        
        while (i < proof_length) {
            let proof_element = *vector::borrow(proof, i);
            computed_hash = commutative_keccak256(computed_hash, proof_element);
            i = i + 1;
        };
        
        computed_hash
    }

    /// Commutative Keccak256 hash (sorted pair)
    fun commutative_keccak256(a: vector<u8>, b: vector<u8>): vector<u8> {
        if (is_less_than(&a, &b)) {
            efficient_keccak256(a, b)
        } else {
            efficient_keccak256(b, a)
        }
    }

    /// Efficient Keccak256 of two concatenated byte arrays
    fun efficient_keccak256(a: vector<u8>, b: vector<u8>): vector<u8> {
        let combined = a;
        vector::append(&mut combined, b);
        hash::sha3_256(combined) // Using SHA3-256 as Keccak256 equivalent
    }

    /// Compares two byte vectors lexicographically
    fun is_less_than(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = vector::length(a);
        let len_b = vector::length(b);
        let min_len = if (len_a < len_b) len_a else len_b;
        
        let i = 0;
        while (i < min_len) {
            let byte_a = *vector::borrow(a, i);
            let byte_b = *vector::borrow(b, i);
            if (byte_a < byte_b) return true;
            if (byte_a > byte_b) return false;
            i = i + 1;
        };
        
        len_a < len_b
    }

    /// Calculates a leaf hash from index and secret hash
    fun calculate_leaf(idx: u64, secret_hash: &vector<u8>): vector<u8> {
        let leaf_data = std::bcs::to_bytes(&idx);
        vector::append(&mut leaf_data, *secret_hash);
        hash::sha3_256(leaf_data)
    }

    /// Generates a validation key from order hash and shortened root
    fun generate_validation_key(order_hash: &vector<u8>, root_shortened: &vector<u8>): vector<u8> {
        let key_data = *order_hash;
        vector::append(&mut key_data, *root_shortened);
        hash::sha3_256(key_data)
    }

    /// Stores validation data in the storage
    fun store_validation(storage: &mut MerkleStorage, key: vector<u8>, validation_data: ValidationData) {
        // Check if key already exists and update, otherwise add new entry
        let validations_len = vector::length(&storage.validations);
        let i = 0;
        let found = false;
        
        while (i < validations_len) {
            let entry = vector::borrow_mut(&mut storage.validations, i);
            if (entry.key == key) {
                entry.validation_data = validation_data;
                found = true;
                break
            };
            i = i + 1;
        };
        
        if (!found) {
            vector::push_back(&mut storage.validations, ValidationEntry {
                key,
                validation_data,
            });
        };
    }

    /// Retrieves last validation data for a given key
    public fun get_last_validated(
        storage_addr: address,
        order_hash: &vector<u8>,
        root_shortened: &vector<u8>
    ): (u64, vector<u8>) acquires MerkleStorage {
        if (!exists<MerkleStorage>(storage_addr)) {
            return (0, vector::empty())
        };
        
        let storage = borrow_global<MerkleStorage>(storage_addr);
        let key = generate_validation_key(order_hash, root_shortened);
        
        let validations_len = vector::length(&storage.validations);
        let i = 0;
        
        while (i < validations_len) {
            let entry = vector::borrow(&storage.validations, i);
            if (entry.key == key) {
                return (entry.validation_data.index, entry.validation_data.secret_hash)
            };
            i = i + 1;
        };
        
        (0, vector::empty())
    }

    /// Validates a partial fill based on making amounts and validation index
    public fun is_valid_partial_fill(
        making_amount: u64,
        remaining_making_amount: u64,
        order_making_amount: u64,
        parts_amount: u64,
        validated_index: u64
    ): bool {
        if (parts_amount == 0 || order_making_amount == 0) {
            return false
        };

        let calculated_index = (order_making_amount - remaining_making_amount + making_amount - 1) 
                               * parts_amount / order_making_amount;

        if (remaining_making_amount == making_amount) {
            // Order filled to completion - secret with index i+1 must be used
            return (calculated_index + 2 == validated_index)
        } else if (order_making_amount != remaining_making_amount) {
            // Not the first fill - check previous index
            let prev_calculated_index = (order_making_amount - remaining_making_amount - 1) 
                                        * parts_amount / order_making_amount;
            if (calculated_index == prev_calculated_index) {
                return false
            };
        };

        calculated_index + 1 == validated_index
    }

    /// Verifies if a secret hash is valid for a given hashlock
    public fun verify_secret_hash(secret: &vector<u8>, expected_hash: &vector<u8>): bool {
        let actual_hash = hash::sha3_256(*secret);
        actual_hash == *expected_hash
    }

    // View functions
    public fun get_validation_count(storage_addr: address): u64 acquires MerkleStorage {
        if (!exists<MerkleStorage>(storage_addr)) {
            0
        } else {
            let storage = borrow_global<MerkleStorage>(storage_addr);
            vector::length(&storage.validations)
        }
    }

    // Getter functions for MultipleFillConfig
    public fun get_root_hash(config: &MultipleFillConfig): vector<u8> { config.root_hash }
    public fun get_parts_amount(config: &MultipleFillConfig): u64 { config.parts_amount }
    public fun get_root_shortened(config: &MultipleFillConfig): vector<u8> { config.root_shortened }

    // Getter functions for TakerData
    public fun get_proof(data: &TakerData): vector<vector<u8>> { data.proof }
    public fun get_idx(data: &TakerData): u64 { data.idx }
    public fun get_secret_hash(data: &TakerData): vector<u8> { data.secret_hash }

    // Getter functions for ValidationData
    public fun get_validation_index(data: &ValidationData): u64 { data.index }
    public fun get_validation_secret_hash(data: &ValidationData): vector<u8> { data.secret_hash }
}