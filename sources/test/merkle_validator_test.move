#[test_only]
module crosschain_escrow_factory::merkle_validator_test {
    use std::vector;
    use std::hash;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    
    use crosschain_escrow_factory::merkle_validator;

    // Test constants
    const TEST_ACCOUNT: address = @0x123456789abcdef123456789abcdef123456789abcdef123456789abcdef12;

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_new_multiple_fill_config(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Create a 32-byte root hash
        let root_hash = b"test_root_hash_32_bytes_long!!!!";
        assert!(vector::length(&root_hash) == 32, 1);
        
        let config = merkle_validator::new_multiple_fill_config(root_hash, 4);
        
        // Test getters
        assert!(merkle_validator::get_root_hash(&config) == root_hash, 2);
        assert!(merkle_validator::get_parts_amount(&config) == 4, 3);
        
        // Test shortened root (first 30 bytes)
        let shortened = merkle_validator::get_root_shortened(&config);
        assert!(vector::length(&shortened) == 30, 4);
        
        let i = 0;
        while (i < 30) {
            assert!(*vector::borrow(&shortened, i) == *vector::borrow(&root_hash, i), 5 + i);
            i = i + 1;
        };
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    #[expected_failure(abort_code = 65542, location = crosschain_escrow_factory::merkle_validator)]
    public fun test_new_multiple_fill_config_invalid_parts(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let root_hash = b"test_root_hash_32_bytes_long!!!!";
        
        // Should fail with parts_amount < 2
        merkle_validator::new_multiple_fill_config(root_hash, 1);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    #[expected_failure(abort_code = 65537, location = crosschain_escrow_factory::merkle_validator)]
    public fun test_new_multiple_fill_config_invalid_root_length(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let short_root = b"short_root";
        
        // Should fail with root_hash length != 32
        merkle_validator::new_multiple_fill_config(short_root, 4);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_new_taker_data(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, b"proof_element_1");
        vector::push_back(&mut proof, b"proof_element_2");
        
        let idx = 3;
        let secret_hash = b"secret_hash_for_testing_purposes";
        
        let taker_data = merkle_validator::new_taker_data(proof, idx, secret_hash);
        
        // Test getters
        let retrieved_proof = merkle_validator::get_proof(&taker_data);
        assert!(vector::length(&retrieved_proof) == 2, 1);
        assert!(*vector::borrow(&retrieved_proof, 0) == b"proof_element_1", 2);
        assert!(*vector::borrow(&retrieved_proof, 1) == b"proof_element_2", 3);
        
        assert!(merkle_validator::get_idx(&taker_data) == idx, 4);
        assert!(merkle_validator::get_secret_hash(&taker_data) == secret_hash, 5);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_process_proof_empty(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let empty_proof = vector::empty<vector<u8>>();
        let leaf = b"test_leaf_data";
        
        let result = merkle_validator::process_proof(&empty_proof, leaf);
        
        // With empty proof, result should be the leaf itself
        assert!(result == leaf, 1);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_process_proof_single_element(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, b"sibling_hash");
        
        let leaf = b"test_leaf";
        let result = merkle_validator::process_proof(&proof, leaf);
        
        // Result should be hash of (leaf, sibling) or (sibling, leaf) depending on ordering
        // We can't predict the exact result without knowing the internal hash function,
        // but we can verify it's not the original leaf
        assert!(result != leaf, 1);
        assert!(vector::length(&result) == 32, 2); // SHA3-256 produces 32-byte output
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_process_proof_multiple_elements(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, b"sibling_1");
        vector::push_back(&mut proof, b"sibling_2");
        vector::push_back(&mut proof, b"sibling_3");
        
        let leaf = b"test_leaf";
        let result = merkle_validator::process_proof(&proof, leaf);
        
        // Result should be different from leaf and have correct length
        assert!(result != leaf, 1);
        assert!(vector::length(&result) == 32, 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_verify_secret_hash(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        let secret = b"my_secret_password";
        let expected_hash = hash::sha3_256(secret);
        
        // Should verify correctly
        assert!(merkle_validator::verify_secret_hash(&secret, &expected_hash), 1);
        
        // Should fail with wrong hash
        let wrong_hash = b"wrong_hash_definitely_not_right!!";
        assert!(!merkle_validator::verify_secret_hash(&secret, &wrong_hash), 2);
        
        // Should fail with wrong secret
        let wrong_secret = b"wrong_secret";
        assert!(!merkle_validator::verify_secret_hash(&wrong_secret, &expected_hash), 3);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_is_valid_partial_fill_edge_cases(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test with zero parts_amount - should return false
        assert!(!merkle_validator::is_valid_partial_fill(100, 100, 1000, 0, 1), 1);
        
        // Test with zero order_making_amount - should return false
        assert!(!merkle_validator::is_valid_partial_fill(100, 100, 0, 4, 1), 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_is_valid_partial_fill_completion(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test order completion scenario
        let making_amount = 1000;      // Fill entire remaining amount
        let remaining_making_amount = 1000; // Same as making_amount = completion
        let order_making_amount = 1000;
        let parts_amount = 4;
        
        // calculated_index = (1000 - 1000 + 1000 - 1) * 4 / 1000 = 999 * 4 / 1000 = 3
        // For completion: should check if calculated_index + 2 == validated_index
        // So validated_index should be 5
        let validated_index = 5;
        
        assert!(merkle_validator::is_valid_partial_fill(
            making_amount,
            remaining_making_amount, 
            order_making_amount,
            parts_amount,
            validated_index
        ), 1);
        
        // Test with wrong validated_index for completion
        assert!(!merkle_validator::is_valid_partial_fill(
            making_amount,
            remaining_making_amount,
            order_making_amount,
            parts_amount,
            4 // Should be 5
        ), 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_is_valid_partial_fill_partial(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test partial fill scenario (not first fill, not completion)
        let making_amount = 250;       // Fill 1/4 of order
        let remaining_making_amount = 500; // Half already filled
        let order_making_amount = 1000;
        let parts_amount = 4;
        
        // calculated_index = (1000 - 500 + 250 - 1) * 4 / 1000 = 749 * 4 / 1000 = 2
        // prev_calculated_index = (1000 - 500 - 1) * 4 / 1000 = 499 * 4 / 1000 = 1
        // Since 2 != 1, should check if calculated_index + 1 == validated_index
        // So validated_index should be 3
        let validated_index = 3;
        
        assert!(merkle_validator::is_valid_partial_fill(
            making_amount,
            remaining_making_amount,
            order_making_amount,
            parts_amount,
            validated_index
        ), 1);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_is_valid_partial_fill_same_index_rejection(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test scenario where calculated_index == prev_calculated_index (should fail)
        let making_amount = 100;
        let remaining_making_amount = 900; // Very small previous fill
        let order_making_amount = 1000;
        let parts_amount = 4;
        
        // Create scenario where both calculated indices are the same
        // calculated_index = (1000 - 900 + 100 - 1) * 4 / 1000 = 199 * 4 / 1000 = 0
        // prev_calculated_index = (1000 - 900 - 1) * 4 / 1000 = 99 * 4 / 1000 = 0
        // Since they're equal, should return false
        assert!(!merkle_validator::is_valid_partial_fill(
            making_amount,
            remaining_making_amount,
            order_making_amount,
            parts_amount,
            1 // Any validated_index
        ), 1);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_initialization_and_storage(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        // Initially no storage should exist
        assert!(merkle_validator::get_validation_count(account_addr) == 0, 1);
        
        // Initialize storage
        merkle_validator::initialize(account);
        
        // After initialization, count should still be 0 but storage should exist
        assert!(merkle_validator::get_validation_count(account_addr) == 0, 2);
        
        // Test double initialization (should not fail)
        merkle_validator::initialize(account);
        assert!(merkle_validator::get_validation_count(account_addr) == 0, 3);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_get_last_validated_nonexistent(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        let order_hash = b"test_order_hash";
        let root_shortened = b"shortened_root_30_bytes_long!!";
        
        // Should return (0, empty) for non-existent storage
        let (index, secret_hash) = merkle_validator::get_last_validated(
            account_addr,
            &order_hash,
            &root_shortened
        );
        
        assert!(index == 0, 1);
        assert!(vector::length(&secret_hash) == 0, 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_validate_and_store_proof_success(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1000000);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        // Create a simple Merkle tree with just one element (leaf = root)
        let secret_hash = b"test_secret_hash_32_bytes_long!!";
        let idx = 0;
        
        // Calculate leaf hash: SHA3-256(BCS(idx) + secret_hash)
        let leaf_data = std::bcs::to_bytes(&idx);
        vector::append(&mut leaf_data, secret_hash);
        let leaf = hash::sha3_256(leaf_data);
        
        // For single element tree, root = leaf
        let root_hash = leaf;
        
        let config = merkle_validator::new_multiple_fill_config(root_hash, 2);
        
        // Empty proof for single element tree
        let proof = vector::empty<vector<u8>>();
        let taker_data = merkle_validator::new_taker_data(proof, idx, secret_hash);
        
        let order_hash = b"test_order_hash";
        
        // This should succeed
        merkle_validator::validate_and_store_proof(
            account,
            order_hash,
            &config,
            &taker_data
        );
        
        // Verify storage was updated
        assert!(merkle_validator::get_validation_count(account_addr) == 1, 1);
        
        // Verify we can retrieve the validation
        let root_shortened = merkle_validator::get_root_shortened(&config);
        let (stored_index, stored_secret) = merkle_validator::get_last_validated(
            account_addr,
            &order_hash,
            &root_shortened
        );
        
        assert!(stored_index == idx + 1, 2); // Should store next expected index
        assert!(stored_secret == secret_hash, 3);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    #[expected_failure(abort_code = 65537, location = crosschain_escrow_factory::merkle_validator)]
    public fun test_validate_and_store_proof_invalid_proof(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        // Create invalid proof scenario
        let root_hash = b"correct_root_hash_32_bytes_long!";
        let config = merkle_validator::new_multiple_fill_config(root_hash, 2);
        
        let secret_hash = b"test_secret_hash";
        let idx = 0;
        
        // Wrong proof that won't match the root
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, b"wrong_proof_element");
        
        let taker_data = merkle_validator::new_taker_data(proof, idx, secret_hash);
        let order_hash = b"test_order";
        
        // Should fail with E_INVALID_PROOF
        merkle_validator::validate_and_store_proof(
            account,
            order_hash,
            &config,
            &taker_data
        );
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_multiple_validations_same_order(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1000000);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        // Create first validation
        let secret_hash1 = b"secret_hash_1_32_bytes_length!!!";
        let idx1 = 0;
        let leaf_data1 = std::bcs::to_bytes(&idx1);
        vector::append(&mut leaf_data1, secret_hash1);
        let root_hash = hash::sha3_256(leaf_data1);
        
        let config = merkle_validator::new_multiple_fill_config(root_hash, 2);
        let proof1 = vector::empty<vector<u8>>();
        let taker_data1 = merkle_validator::new_taker_data(proof1, idx1, secret_hash1);
        let order_hash = b"same_order_hash";
        
        merkle_validator::validate_and_store_proof(
            account,
            order_hash,
            &config,
            &taker_data1
        );
        
        // Now update the same order with new validation (simulating next index)
        let secret_hash2 = b"secret_hash_2_32_bytes_length!!!";
        let idx2 = 1;
        let leaf_data2 = std::bcs::to_bytes(&idx2);
        vector::append(&mut leaf_data2, secret_hash2);
        let root_hash2 = hash::sha3_256(leaf_data2);
        
        let config2 = merkle_validator::new_multiple_fill_config(root_hash2, 2);
        let proof2 = vector::empty<vector<u8>>();
        let taker_data2 = merkle_validator::new_taker_data(proof2, idx2, secret_hash2);
        
        merkle_validator::validate_and_store_proof(
            account,
            order_hash,
            &config2,
            &taker_data2
        );
        
        // Should still have just 2 entries (one per unique root)
        assert!(merkle_validator::get_validation_count(account_addr) == 2, 1);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_lexicographic_comparison_edge_cases(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test commutative hash with identical inputs
        let data = b"identical_data";
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, data);
        
        let result1 = merkle_validator::process_proof(&proof, data);
        let result2 = merkle_validator::process_proof(&proof, data);
        
        // Results should be identical for identical inputs
        assert!(result1 == result2, 1);
        
        // Test with different length vectors
        let short_vec = b"short";
        let long_vec = b"much_longer_vector";
        let proof_mixed = vector::empty<vector<u8>>();
        vector::push_back(&mut proof_mixed, long_vec);
        
        let result_short = merkle_validator::process_proof(&proof_mixed, short_vec);
        assert!(vector::length(&result_short) == 32, 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_large_merkle_proof(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test with larger proof (simulating deeper tree)
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, b"level_1_sibling");
        vector::push_back(&mut proof, b"level_2_sibling");
        vector::push_back(&mut proof, b"level_3_sibling");
        vector::push_back(&mut proof, b"level_4_sibling");
        vector::push_back(&mut proof, b"level_5_sibling");
        
        let leaf = b"deep_leaf_node";
        let root = merkle_validator::process_proof(&proof, leaf);
        
        // Root should be different from leaf and have correct length
        assert!(root != leaf, 1);
        assert!(vector::length(&root) == 32, 2);
        
        // Test that proof processing is deterministic
        let root2 = merkle_validator::process_proof(&proof, leaf);
        assert!(root == root2, 3);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_partial_fill_validation_comprehensive(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test first fill scenario
        let making_amount = 250;
        let remaining_making_amount = 1000; // First fill
        let order_making_amount = 1000;
        let parts_amount = 4;
        
        // calculated_index = (1000 - 1000 + 250 - 1) * 4 / 1000 = 249 * 4 / 1000 = 0
        // For non-completion, non-first-fill case, should check calculated_index + 1 == validated_index
        // So validated_index should be 1
        let validated_index = 1;
        
        assert!(merkle_validator::is_valid_partial_fill(
            making_amount,
            remaining_making_amount,
            order_making_amount,
            parts_amount,
            validated_index
        ), 1);
        
        // Test with wrong index
        assert!(!merkle_validator::is_valid_partial_fill(
            making_amount,
            remaining_making_amount,
            order_making_amount,
            parts_amount,
            2 // Wrong index
        ), 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_validation_data_getters(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1000000);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        // Set up a simple validation
        let secret_hash = b"test_secret_for_getter_validation";
        let idx = 5;
        let leaf_data = std::bcs::to_bytes(&idx);
        vector::append(&mut leaf_data, secret_hash);
        let root_hash = hash::sha3_256(leaf_data);
        
        let config = merkle_validator::new_multiple_fill_config(root_hash, 3);
        let proof = vector::empty<vector<u8>>();
        let taker_data = merkle_validator::new_taker_data(proof, idx, secret_hash);
        let order_hash = b"getter_test_order";
        
        merkle_validator::validate_and_store_proof(
            account,
            order_hash,
            &config,
            &taker_data
        );
        
        // Test all getter functions work correctly
        assert!(merkle_validator::get_parts_amount(&config) == 3, 1);
        assert!(vector::length(&merkle_validator::get_root_hash(&config)) == 32, 2);
        assert!(vector::length(&merkle_validator::get_root_shortened(&config)) == 30, 3);
        
        assert!(merkle_validator::get_idx(&taker_data) == idx, 4);
        assert!(merkle_validator::get_secret_hash(&taker_data) == secret_hash, 5);
        assert!(vector::length(&merkle_validator::get_proof(&taker_data)) == 0, 6);
        
        // Verify stored validation
        let root_shortened = merkle_validator::get_root_shortened(&config);
        let (stored_index, stored_secret) = merkle_validator::get_last_validated(
            account_addr,
            &order_hash,
            &root_shortened
        );
        
        assert!(stored_index == idx + 1, 7);
        assert!(stored_secret == secret_hash, 8);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_edge_case_zero_index(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1000000);
        let account_addr = std::signer::address_of(account);
        account::create_account_for_test(account_addr);
        
        // Test with index 0 (edge case)
        let secret_hash = b"zero_index_secret_hash_32_bytes!";
        let idx = 0;
        let leaf_data = std::bcs::to_bytes(&idx);
        vector::append(&mut leaf_data, secret_hash);
        let root_hash = hash::sha3_256(leaf_data);
        
        let config = merkle_validator::new_multiple_fill_config(root_hash, 2);
        let proof = vector::empty<vector<u8>>();
        let taker_data = merkle_validator::new_taker_data(proof, idx, secret_hash);
        let order_hash = b"zero_index_order";
        
        merkle_validator::validate_and_store_proof(
            account,
            order_hash,
            &config,
            &taker_data
        );
        
        // Verify storage
        let root_shortened = merkle_validator::get_root_shortened(&config);
        let (stored_index, stored_secret) = merkle_validator::get_last_validated(
            account_addr,
            &order_hash,
            &root_shortened
        );
        
        assert!(stored_index == 1, 1); // Should store idx + 1 = 1
        assert!(stored_secret == secret_hash, 2);
    }

    #[test(framework = @aptos_framework, account = @0x123)]
    public fun test_hash_consistency(framework: &signer, account: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(std::signer::address_of(account));
        
        // Test that the same secret always produces the same hash
        let secret1 = b"consistent_secret_test";
        let secret2 = b"consistent_secret_test";
        
        let hash1 = hash::sha3_256(secret1);
        let hash2 = hash::sha3_256(secret2);
        
        assert!(hash1 == hash2, 1);
        assert!(merkle_validator::verify_secret_hash(&secret1, &hash2), 2);
        assert!(merkle_validator::verify_secret_hash(&secret2, &hash1), 3);
        
        // Test different secrets produce different hashes
        let different_secret = b"different_secret_test";
        let different_hash = hash::sha3_256(different_secret);
        
        assert!(hash1 != different_hash, 4);
        assert!(!merkle_validator::verify_secret_hash(&secret1, &different_hash), 5);
    }
}