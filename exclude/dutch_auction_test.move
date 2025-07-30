#[test_only]
module crosschain_escrow_factory::dutch_auction_test {
    use std::vector;
    use aptos_framework::timestamp;
    
    use crosschain_escrow_factory::dutch_auction;

    const TEST_BASE_TIME: u64 = 1000000; // Base timestamp for testing
    const TEST_GAS_PRICE: u64 = 2000000; // 2 Gwei equivalent

    #[test(framework = @aptos_framework)]
    public fun test_new_auction_point(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let point = dutch_auction::new_auction_point(5000, 60);
        
        assert!(dutch_auction::get_point_rate_bump(&point) == 5000, 1);
        assert!(dutch_auction::get_point_time_delta(&point) == 60, 2);
    }

    #[test(framework = @aptos_framework)]
    public fun test_new_auction_config_valid(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        vector::push_back(&mut points, dutch_auction::new_auction_point(8000, 30));
        vector::push_back(&mut points, dutch_auction::new_auction_point(5000, 60));
        vector::push_back(&mut points, dutch_auction::new_auction_point(2000, 90));
        
        let config = dutch_auction::new_auction_config(
            1000,     // gas_bump_estimate
            2000000,  // gas_price_estimate (2 Gwei)
            (TEST_BASE_TIME as u32), // start_time
            300,      // duration (5 minutes)
            10000,    // initial_rate_bump (100 basis points)
            points
        );
        
        assert!(dutch_auction::get_gas_bump_estimate(&config) == 1000, 1);
        assert!(dutch_auction::get_gas_price_estimate(&config) == 2000000, 2);
        assert!(dutch_auction::get_start_time(&config) == (TEST_BASE_TIME as u32), 3);
        assert!(dutch_auction::get_duration(&config) == 300, 4);
        assert!(dutch_auction::get_initial_rate_bump(&config) == 10000, 5);
        
        let retrieved_points = dutch_auction::get_auction_points(&config);
        assert!(vector::length(&retrieved_points) == 3, 6);
    }

    #[test(framework = @aptos_framework)]
    public fun test_auction_config_empty_points(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let empty_points = vector::empty<dutch_auction::AuctionPoint>();
        
        let config = dutch_auction::new_auction_config(
            500,
            1500000,
            (TEST_BASE_TIME as u32),
            180,
            5000,
            empty_points
        );
        
        let points = dutch_auction::get_auction_points(&config);
        assert!(vector::length(&points) == 0, 1);
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 65538, location = crosschain_escrow_factory::dutch_auction)]
    public fun test_auction_config_invalid_points(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let invalid_points = vector::empty<dutch_auction::AuctionPoint>();
        // Create a point with zero time delta (invalid except for first point)
        vector::push_back(&mut invalid_points, dutch_auction::new_auction_point(5000, 30));
        vector::push_back(&mut invalid_points, dutch_auction::new_auction_point(3000, 0)); // Invalid!
        
        // Should fail due to zero time delta
        dutch_auction::new_auction_config(
            1000,
            2000000,
            (TEST_BASE_TIME as u32),
            300,
            10000,
            invalid_points
        );
    }

    #[test(framework = @aptos_framework)]
    public fun test_calculate_gas_bump(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        let config = dutch_auction::new_auction_config(
            2000000,  // gas_bump_estimate
            1000000,  // gas_price_estimate (1 Gwei)
            (TEST_BASE_TIME as u32),
            300,
            5000,
            points
        );
        
        // Test with 2 Gwei current gas price
        let current_gas_price = 2000000; // 2 Gwei
        
        // Gas bump should be: 2000000 * 2000000 / 1000000 / 1000000 = 4
        // But auction hasn't started, so we get initial_rate_bump - gas_bump
        // Since we haven't set current time, auction hasn't started
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME - 100);
        let rate_bump_before = dutch_auction::calculate_rate_bump(&config, current_gas_price);
        
        // Should return initial_rate_bump (5000) - gas_bump (4) = 4996
        assert!(rate_bump_before == 4996, 1);
    }

    #[test(framework = @aptos_framework)]
    public fun test_auction_phases(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        let config = dutch_auction::new_auction_config(
            1000,
            2000000,
            (TEST_BASE_TIME as u32),
            300, // 5 minutes
            10000,
            points
        );
        
        // Before auction starts
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME - 100);
        assert!(!dutch_auction::has_auction_started(&config), 1);
        assert!(!dutch_auction::has_auction_finished(&config), 2);
        assert!(dutch_auction::get_auction_phase(&config) == 0, 3);
        assert!(dutch_auction::get_auction_progress(&config) == 0, 4);
        
        // During auction
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 150); // 2.5 minutes in
        assert!(dutch_auction::has_auction_started(&config), 5);
        assert!(!dutch_auction::has_auction_finished(&config), 6);
        assert!(dutch_auction::get_auction_phase(&config) == 1, 7);
        assert!(dutch_auction::get_auction_progress(&config) == 50, 8); // 50% through
        
        // After auction ends
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 400); // Past 5 minutes
        assert!(dutch_auction::has_auction_started(&config), 9);
        assert!(dutch_auction::has_auction_finished(&config), 10);
        assert!(dutch_auction::get_auction_phase(&config) == 2, 11);
        assert!(dutch_auction::get_auction_progress(&config) == 100, 12);
    }

    #[test(framework = @aptos_framework)]
    public fun test_auction_finish_time(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        let config = dutch_auction::new_auction_config(
            1000,
            2000000,
            (TEST_BASE_TIME as u32),
            180, // 3 minutes
            5000,
            points
        );
        
        let finish_time = dutch_auction::get_auction_finish_time(&config);
        assert!(finish_time == TEST_BASE_TIME + 180, 1);
    }

    #[test(framework = @aptos_framework)]
    public fun test_calculate_making_amount(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test making amount calculation
        // order: 100 USDC for 1000 tokens
        // taking: 500 tokens
        // rate_bump: 5000 (50 basis points = 0.5%)
        
        let order_making_amount = 100_000_000; // 100 USDC (6 decimals)
        let order_taking_amount = 1000_000_000; // 1000 tokens (6 decimals)
        let taking_amount = 500_000_000; // 500 tokens
        let rate_bump = 5000; // 0.5%
        
        let making_amount = dutch_auction::calculate_making_amount(
            order_making_amount,
            order_taking_amount,
            taking_amount,
            rate_bump
        );
        
        // Expected: 100 * 500 * 10,000,000 / (1000 * (10,000,000 + 5000))
        // = 500,000,000,000,000 / 10,005,000,000
        // ≈ 49,975,012 (approximately 49.975 USDC)
        assert!(making_amount > 49_900_000 && making_amount < 50_000_000, 1);
    }

    #[test(framework = @aptos_framework)]
    public fun test_calculate_taking_amount(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test taking amount calculation (ceiling division)
        let order_making_amount = 100_000_000; // 100 USDC
        let order_taking_amount = 1000_000_000; // 1000 tokens
        let making_amount = 50_000_000; // 50 USDC
        let rate_bump = 5000; // 0.5%
        
        let taking_amount = dutch_auction::calculate_taking_amount(
            order_making_amount,
            order_taking_amount,
            making_amount,
            rate_bump
        );
        
        // Expected with ceiling: 1000 * 50 * (10,000,000 + 5000) / (100 * 10,000,000)
        // = 500,250,000,000 / 1,000,000,000 = 500.25 → ceiling to 501 tokens
        assert!(taking_amount >= 500_000_000, 1);
        assert!(taking_amount <= 502_000_000, 2); // Allow some margin for precision
    }

    #[test(framework = @aptos_framework)]
    public fun test_piecewise_rate_bump_calculation(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        vector::push_back(&mut points, dutch_auction::new_auction_point(8000, 60));  // 8% at 1 minute
        vector::push_back(&mut points, dutch_auction::new_auction_point(5000, 60));  // 5% at 2 minutes
        vector::push_back(&mut points, dutch_auction::new_auction_point(2000, 60));  // 2% at 3 minutes
        
        let config = dutch_auction::new_auction_config(
            0, // No gas bump for this test
            1000000,
            (TEST_BASE_TIME as u32),
            240, // 4 minutes total
            10000, // 10% initial
            points
        );
        
        // At auction start - should be initial rate bump
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME);
        let rate_bump_start = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_bump_start == 10000, 1);
        
        // At 30 seconds - interpolating between 10% and 8%
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 30);
        let rate_bump_30s = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_bump_30s == 9000, 2); // Should be 9% (halfway between 10% and 8%)
        
        // At 90 seconds - interpolating between 8% and 5%
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 90);
        let rate_bump_90s = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_bump_90s == 6500, 3); // Should be 6.5% (halfway between 8% and 5%)
        
        // After auction ends - should be 0
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 300);
        let rate_bump_end = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_bump_end == 0, 4);
    }

    #[test(framework = @aptos_framework)]
    public fun test_gas_bump_calculation_edge_cases(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test with zero gas estimates
        let points = vector::empty<dutch_auction::AuctionPoint>();
        let config_zero_gas = dutch_auction::new_auction_config(
            0, // zero gas_bump_estimate
            0, // zero gas_price_estimate
            (TEST_BASE_TIME as u32),
            300,
            5000,
            points
        );
        
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME);
        let rate_bump = dutch_auction::calculate_rate_bump(&config_zero_gas, 2000000);
        assert!(rate_bump == 5000, 1); // Should return initial rate bump at auction start
        
        // Test with reasonable gas price that doesn't overwhelm auction bump
        let config_normal = dutch_auction::new_auction_config(
            100000,   // 100k gas bump estimate (smaller than before)
            2000000,  // 2 Gwei gas price estimate
            ((TEST_BASE_TIME + 10) as u32), // Start auction 10 seconds later
            300,
            5000,     // Initial rate bump
            points
        );
        
        // At auction start with reasonable gas price
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 10);
        let reasonable_gas_price = 2000000; // 2 Gwei
        let rate_bump_normal = dutch_auction::calculate_rate_bump(&config_normal, reasonable_gas_price);
        // Gas bump should be: 100000 * 2000000 / 2000000 / 1000000 = 100
        // Initial auction bump is 5000, so result should be 5000 - 100 = 4900
        assert!(rate_bump_normal >= 4800 && rate_bump_normal <= 5000, 2);
    }

    #[test(framework = @aptos_framework)]
    public fun test_linear_interpolation_edge_cases(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test with single point that has immediate jump
        let points = vector::empty<dutch_auction::AuctionPoint>();
        vector::push_back(&mut points, dutch_auction::new_auction_point(0, 1)); // Jump to 0% after 1 second
        
        let config = dutch_auction::new_auction_config(
            0,
            1000000,
            (TEST_BASE_TIME as u32),
            10, // Very short auction
            10000, // Start at 10%
            points
        );
        
        // Just after start - should still be close to initial
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME);
        let rate_bump_start = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_bump_start == 10000, 1);
        
        // Just after the point - should be 0
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 2);
        let rate_bump_after = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_bump_after < 5000, 2); // Should be much lower, interpolating to final 0
    }

    #[test(framework = @aptos_framework)]
    public fun test_base_points_and_constants(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        assert!(dutch_auction::base_points() == 10_000_000, 1); // 100% in basis points
        assert!(dutch_auction::gas_price_base() == 1_000_000, 2); // 1000 = 1 Gwei equivalent
    }

    #[test(framework = @aptos_framework)]
    public fun test_auction_progress_precision(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        let config = dutch_auction::new_auction_config(
            1000,
            2000000,
            (TEST_BASE_TIME as u32),
            1000, // 1000 seconds for easy percentage calculation
            5000,
            points
        );
        
        // Test various progress points
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 100);
        assert!(dutch_auction::get_auction_progress(&config) == 10, 1); // 10%
        
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 250);
        assert!(dutch_auction::get_auction_progress(&config) == 25, 2); // 25%
        
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 750);
        assert!(dutch_auction::get_auction_progress(&config) == 75, 3); // 75%
        
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 999);
        assert!(dutch_auction::get_auction_progress(&config) == 99, 4); // 99%
    }

    #[test(framework = @aptos_framework)]
    public fun test_complex_piecewise_auction(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Create a complex auction with multiple segments
        let points = vector::empty<dutch_auction::AuctionPoint>();
        vector::push_back(&mut points, dutch_auction::new_auction_point(12000, 30));  // 12% at 30s
        vector::push_back(&mut points, dutch_auction::new_auction_point(8000, 60));   // 8% at 90s total
        vector::push_back(&mut points, dutch_auction::new_auction_point(6000, 30));   // 6% at 120s total
        vector::push_back(&mut points, dutch_auction::new_auction_point(3000, 60));   // 3% at 180s total
        vector::push_back(&mut points, dutch_auction::new_auction_point(1000, 120));  // 1% at 300s total
        
        let config = dutch_auction::new_auction_config(
            0, // No gas bump
            1000000,
            (TEST_BASE_TIME as u32),
            360, // 6 minutes total
            15000, // Start at 15%
            points
        );
        
        // Test at various points in the complex curve
        
        // At start - 15%
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME);
        let rate_0 = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_0 == 15000, 1);
        
        // At 15s - halfway to first point (interpolating from 15% to 12%)
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        let rate_15 = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_15 == 13500, 2); // Should be 13.5%
        
        // At 30s - first point (12%)
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 30);
        let rate_30 = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_30 == 12000, 3);
        
        // At 60s - halfway between first and second point (interpolating from 12% to 8%)
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 60);
        let rate_60 = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_60 == 10000, 4); // Should be 10%
        
        // After auction ends - should be 0
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 400);
        let rate_end = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_end == 0, 5);
    }

    #[test(framework = @aptos_framework)]
    public fun test_making_taking_amount_precision(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test with small amounts to verify precision
        let order_making = 1000; // 0.001 token
        let order_taking = 2000;  // 0.002 token
        let taking = 1000;        // 0.001 token
        let rate_bump = 100;      // 0.01%
        
        let making = dutch_auction::calculate_making_amount(
            order_making,
            order_taking,
            taking,
            rate_bump
        );
        
        // Should get approximately half the making amount with tiny adjustment
        assert!(making > 495 && making < 505, 1);
        
        // Test ceiling division for taking amount
        let taking_calc = dutch_auction::calculate_taking_amount(
            order_making,
            order_taking,
            500, // Half making amount
            rate_bump
        );
        
        // Should be close to 1000 but potentially rounded up
        assert!(taking_calc >= 1000 && taking_calc <= 1002, 2);
    }

    #[test(framework = @aptos_framework)]
    public fun test_zero_duration_auction(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        let config = dutch_auction::new_auction_config(
            0,
            1000000,
            (TEST_BASE_TIME as u32),
            0, // Zero duration
            5000,
            points
        );
        
        // At start time - should still have initial rate
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME);
        let rate_start = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_start == 5000, 1);
        
        // Immediately after start - should be finished (0%)
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 1);
        let rate_after = dutch_auction::calculate_rate_bump(&config, 1000000);
        assert!(rate_after == 0, 2);
        
        assert!(dutch_auction::has_auction_started(&config), 3);
        assert!(dutch_auction::has_auction_finished(&config), 4);
        assert!(dutch_auction::get_auction_progress(&config) == 100, 5);
    }

    #[test(framework = @aptos_framework)]
    public fun test_getter_functions_comprehensive(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test all getter functions with specific values
        let point = dutch_auction::new_auction_point(7500, 45);
        assert!(dutch_auction::get_point_rate_bump(&point) == 7500, 1);
        assert!(dutch_auction::get_point_time_delta(&point) == 45, 2);
        
        let points = vector::empty<dutch_auction::AuctionPoint>();
        vector::push_back(&mut points, point);
        
        let config = dutch_auction::new_auction_config(
            1500,     // gas_bump_estimate
            3000000,  // gas_price_estimate
            ((TEST_BASE_TIME + 100) as u32),
            420,      // duration
            8500,     // initial_rate_bump
            points
        );
        
        assert!(dutch_auction::get_gas_bump_estimate(&config) == 1500, 3);
        assert!(dutch_auction::get_gas_price_estimate(&config) == 3000000, 4);
        assert!(dutch_auction::get_start_time(&config) == ((TEST_BASE_TIME + 100) as u32), 5);
        assert!(dutch_auction::get_duration(&config) == 420, 6);
        assert!(dutch_auction::get_initial_rate_bump(&config) == 8500, 7);
        
        let retrieved_points = dutch_auction::get_auction_points(&config);
        assert!(vector::length(&retrieved_points) == 1, 8);
        
        let first_point = vector::borrow(&retrieved_points, 0);
        assert!(dutch_auction::get_point_rate_bump(first_point) == 7500, 9);
        assert!(dutch_auction::get_point_time_delta(first_point) == 45, 10);
    }
}