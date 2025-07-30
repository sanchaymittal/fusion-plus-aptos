#[test_only]
module crosschain_escrow_factory::timelock_test {
    use std::error;
    use aptos_framework::timestamp;
    
    use crosschain_escrow_factory::timelock;

    const TEST_BASE_TIME: u64 = 1000000; // Base timestamp for testing

    #[test(framework = @aptos_framework)]
    public fun test_new_timelock_valid_delays(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(
            10,  // src_withdrawal_delay
            20,  // src_public_withdrawal_delay
            30,  // src_cancellation_delay
            40,  // src_public_cancellation_delay
            5,   // dst_withdrawal_delay
            15,  // dst_public_withdrawal_delay
            25   // dst_cancellation_delay
        );

        // Check initial state
        assert!(timelock::get_deployed_at(&timelocks) == 0, 1);
        assert!(timelock::get_src_withdrawal_delay(&timelocks) == 10, 2);
        assert!(timelock::get_src_public_withdrawal_delay(&timelocks) == 20, 3);
        assert!(timelock::get_src_cancellation_delay(&timelocks) == 30, 4);
        assert!(timelock::get_src_public_cancellation_delay(&timelocks) == 40, 5);
        assert!(timelock::get_dst_withdrawal_delay(&timelocks) == 5, 6);
        assert!(timelock::get_dst_public_withdrawal_delay(&timelocks) == 15, 7);
        assert!(timelock::get_dst_cancellation_delay(&timelocks) == 25, 8);
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 65537, location = crosschain_escrow_factory::timelock)]
    public fun test_new_timelock_invalid_src_delays(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Should fail: src_withdrawal_delay > src_public_withdrawal_delay
        timelock::new(
            30,  // src_withdrawal_delay
            20,  // src_public_withdrawal_delay (less than withdrawal)
            40,  // src_cancellation_delay
            50,  // src_public_cancellation_delay
            5,   // dst_withdrawal_delay
            15,  // dst_public_withdrawal_delay
            25   // dst_cancellation_delay
        );
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 65537, location = crosschain_escrow_factory::timelock)]
    public fun test_new_timelock_invalid_dst_delays(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Should fail: dst_public_withdrawal_delay > dst_cancellation_delay
        timelock::new(
            10,  // src_withdrawal_delay
            20,  // src_public_withdrawal_delay
            30,  // src_cancellation_delay
            40,  // src_public_cancellation_delay
            5,   // dst_withdrawal_delay
            25,  // dst_public_withdrawal_delay
            15   // dst_cancellation_delay (less than public withdrawal)
        );
    }

    #[test(framework = @aptos_framework)]
    public fun test_set_deployed_at(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        
        timelock::set_deployed_at(&mut timelocks, TEST_BASE_TIME);
        assert!(timelock::get_deployed_at(&timelocks) == TEST_BASE_TIME, 1);
    }

    #[test(framework = @aptos_framework)]
    public fun test_with_deployed_at(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks_deployed = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        assert!(timelock::get_deployed_at(&timelocks_deployed) == TEST_BASE_TIME, 1);
        // Original should still have deployed_at = 0
        assert!(timelock::get_deployed_at(&timelocks) == 0, 2);
    }

    #[test(framework = @aptos_framework)]
    public fun test_stage_constants(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test that stage constants are unique
        assert!(timelock::stage_src_withdrawal() == 0, 1);
        assert!(timelock::stage_src_public_withdrawal() == 1, 2);
        assert!(timelock::stage_src_cancellation() == 2, 3);
        assert!(timelock::stage_src_public_cancellation() == 3, 4);
        assert!(timelock::stage_dst_withdrawal() == 4, 5);
        assert!(timelock::stage_dst_public_withdrawal() == 5, 6);
        assert!(timelock::stage_dst_cancellation() == 6, 7);
        
        // Ensure all are different
        let stages = vector[
            timelock::stage_src_withdrawal(),
            timelock::stage_src_public_withdrawal(),
            timelock::stage_src_cancellation(),
            timelock::stage_src_public_cancellation(),
            timelock::stage_dst_withdrawal(),
            timelock::stage_dst_public_withdrawal(),
            timelock::stage_dst_cancellation()
        ];
        
        // Simple uniqueness check
        assert!(std::vector::length(&stages) == 7, 8);
    }

    #[test(framework = @aptos_framework)]
    public fun test_get_stage_time(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Test all stages
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_src_withdrawal()) == TEST_BASE_TIME + 10, 1);
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_src_public_withdrawal()) == TEST_BASE_TIME + 20, 2);
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_src_cancellation()) == TEST_BASE_TIME + 30, 3);
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_src_public_cancellation()) == TEST_BASE_TIME + 40, 4);
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_dst_withdrawal()) == TEST_BASE_TIME + 5, 5);
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_dst_public_withdrawal()) == TEST_BASE_TIME + 15, 6);
        assert!(timelock::get_stage_time(&timelocks, timelock::stage_dst_cancellation()) == TEST_BASE_TIME + 25, 7);
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 65538, location = crosschain_escrow_factory::timelock)]
    public fun test_get_stage_time_invalid_stage(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should fail with invalid stage
        timelock::get_stage_time(&timelocks, 99);
    }

    #[test(framework = @aptos_framework)]
    public fun test_is_after_stage(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Current time is TEST_BASE_TIME + 15
        // So we should be after stages with delay <= 15
        assert!(timelock::is_after_stage(&timelocks, timelock::stage_src_withdrawal()), 1); // delay 10
        assert!(timelock::is_after_stage(&timelocks, timelock::stage_dst_withdrawal()), 2); // delay 5
        assert!(timelock::is_after_stage(&timelocks, timelock::stage_dst_public_withdrawal()), 3); // delay 15
        
        // Should not be after stages with delay > 15
        assert!(!timelock::is_after_stage(&timelocks, timelock::stage_src_public_withdrawal()), 4); // delay 20
        assert!(!timelock::is_after_stage(&timelocks, timelock::stage_src_cancellation()), 5); // delay 30
    }

    #[test(framework = @aptos_framework)]
    public fun test_is_before_stage(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Current time is TEST_BASE_TIME + 15
        // So we should be before stages with delay > 15
        assert!(timelock::is_before_stage(&timelocks, timelock::stage_src_public_withdrawal()), 1); // delay 20
        assert!(timelock::is_before_stage(&timelocks, timelock::stage_src_cancellation()), 2); // delay 30
        assert!(timelock::is_before_stage(&timelocks, timelock::stage_dst_cancellation()), 3); // delay 25
        
        // Should not be before stages with delay <= 15
        assert!(!timelock::is_before_stage(&timelocks, timelock::stage_src_withdrawal()), 4); // delay 10
        assert!(!timelock::is_before_stage(&timelocks, timelock::stage_dst_withdrawal()), 5); // delay 5
    }

    #[test(framework = @aptos_framework)]
    public fun test_assert_after_stage_success(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should succeed - we're after these stages
        timelock::assert_after_stage(&timelocks, timelock::stage_src_withdrawal());
        timelock::assert_after_stage(&timelocks, timelock::stage_dst_withdrawal());
        timelock::assert_after_stage(&timelocks, timelock::stage_dst_public_withdrawal());
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 196611, location = crosschain_escrow_factory::timelock)]
    public fun test_assert_after_stage_failure(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should fail - we're not after this stage (delay 20, current time is +15)
        timelock::assert_after_stage(&timelocks, timelock::stage_src_public_withdrawal());
    }

    #[test(framework = @aptos_framework)]
    public fun test_assert_before_stage_success(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should succeed - we're before these stages
        timelock::assert_before_stage(&timelocks, timelock::stage_src_public_withdrawal());
        timelock::assert_before_stage(&timelocks, timelock::stage_src_cancellation());
        timelock::assert_before_stage(&timelocks, timelock::stage_dst_cancellation());
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 196612, location = crosschain_escrow_factory::timelock)]
    public fun test_assert_before_stage_failure(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should fail - we're not before this stage (delay 10, current time is +15)
        timelock::assert_before_stage(&timelocks, timelock::stage_src_withdrawal());
    }

    #[test(framework = @aptos_framework)]
    public fun test_is_in_window(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Current time is +15, so we should be in window [src_withdrawal (10), src_public_withdrawal (20)]
        assert!(timelock::is_in_window(
            &timelocks,
            timelock::stage_src_withdrawal(),
            timelock::stage_src_public_withdrawal()
        ), 1);
        
        // Should be in window [dst_withdrawal (5), dst_cancellation (25)] because we're after +5 and before +25
        assert!(timelock::is_in_window(
            &timelocks,
            timelock::stage_dst_withdrawal(),
            timelock::stage_dst_cancellation()
        ), 2);
        
        // Should not be in window [src_public_withdrawal (20), src_cancellation (30)] because we're before +20
        assert!(!timelock::is_in_window(
            &timelocks,
            timelock::stage_src_public_withdrawal(),
            timelock::stage_src_cancellation()
        ), 3);
    }

    #[test(framework = @aptos_framework)]
    public fun test_assert_in_window_success(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should succeed - we're in this window
        timelock::assert_in_window(
            &timelocks,
            timelock::stage_src_withdrawal(),
            timelock::stage_src_public_withdrawal()
        );
    }

    #[test(framework = @aptos_framework)]
    #[expected_failure(abort_code = 196609, location = crosschain_escrow_factory::timelock)]
    public fun test_assert_in_window_failure(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + 15);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should fail - we're not in this window
        timelock::assert_in_window(
            &timelocks,
            timelock::stage_src_public_withdrawal(),
            timelock::stage_src_cancellation()
        );
    }

    #[test(framework = @aptos_framework)]
    public fun test_rescue_functionality(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        let rescue_delay = 3600; // 1 hour
        
        // Test rescue time calculation
        let rescue_start = timelock::get_rescue_start_time(&timelocks, rescue_delay);
        assert!(rescue_start == TEST_BASE_TIME + rescue_delay, 1);
        
        // Before rescue time
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + rescue_delay - 1);
        assert!(!timelock::is_rescue_time(&timelocks, rescue_delay), 2);
        
        // At rescue time
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + rescue_delay);
        assert!(timelock::is_rescue_time(&timelocks, rescue_delay), 3);
        
        // After rescue time
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME + rescue_delay + 100);
        assert!(timelock::is_rescue_time(&timelocks, rescue_delay), 4);
    }

    #[test(framework = @aptos_framework)]
    public fun test_getter_functions(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(11, 22, 33, 44, 55, 66, 77);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        assert!(timelock::get_deployed_at(&timelocks) == TEST_BASE_TIME, 1);
        assert!(timelock::get_src_withdrawal_delay(&timelocks) == 11, 2);
        assert!(timelock::get_src_public_withdrawal_delay(&timelocks) == 22, 3);
        assert!(timelock::get_src_cancellation_delay(&timelocks) == 33, 4);
        assert!(timelock::get_src_public_cancellation_delay(&timelocks) == 44, 5);
        assert!(timelock::get_dst_withdrawal_delay(&timelocks) == 55, 6);
        assert!(timelock::get_dst_public_withdrawal_delay(&timelocks) == 66, 7);
        assert!(timelock::get_dst_cancellation_delay(&timelocks) == 77, 8);
    }

    #[test(framework = @aptos_framework)]
    public fun test_edge_cases_zero_delays(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test with zero delays (all stages happen immediately)
        let timelocks = timelock::new(0, 0, 0, 0, 0, 0, 0);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        timestamp::update_global_time_for_test_secs(TEST_BASE_TIME);
        
        // All stages should be immediately available
        assert!(timelock::is_after_stage(&timelocks, timelock::stage_src_withdrawal()), 1);
        assert!(timelock::is_after_stage(&timelocks, timelock::stage_src_public_withdrawal()), 2);
        assert!(timelock::is_after_stage(&timelocks, timelock::stage_dst_withdrawal()), 3);
    }

    #[test(framework = @aptos_framework)]
    public fun test_large_delays(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        // Test with very large delays
        let large_delay = 4294967295u32; // Max u32 value
        let timelocks = timelock::new(
            large_delay, large_delay, large_delay, large_delay,
            large_delay, large_delay, large_delay
        );
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Should be able to calculate stage times without overflow
        let stage_time = timelock::get_stage_time(&timelocks, timelock::stage_src_withdrawal());
        assert!(stage_time == TEST_BASE_TIME + (large_delay as u64), 1);
    }

    #[test(framework = @aptos_framework)]
    public fun test_time_progression_simulation(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        
        let timelocks = timelock::new(10, 20, 30, 40, 5, 15, 25);
        let timelocks = timelock::with_deployed_at(timelocks, TEST_BASE_TIME);
        
        // Simulate time progression through different stages
        let test_times = vector[
            TEST_BASE_TIME,         // At deployment
            TEST_BASE_TIME + 5,     // dst_withdrawal available
            TEST_BASE_TIME + 10,    // src_withdrawal available
            TEST_BASE_TIME + 15,    // dst_public_withdrawal available
            TEST_BASE_TIME + 20,    // src_public_withdrawal available  
            TEST_BASE_TIME + 25,    // dst_cancellation available
            TEST_BASE_TIME + 30,    // src_cancellation available
            TEST_BASE_TIME + 40     // src_public_cancellation available
        ];
        
        let i = 0;
        while (i < std::vector::length(&test_times)) {
            let test_time = *std::vector::borrow(&test_times, i);
            timestamp::update_global_time_for_test_secs(test_time);
            
            // At each time, verify which stages should be available
            if (test_time >= TEST_BASE_TIME + 5) {
                assert!(timelock::is_after_stage(&timelocks, timelock::stage_dst_withdrawal()), 100 + i);
            };
            if (test_time >= TEST_BASE_TIME + 10) {
                assert!(timelock::is_after_stage(&timelocks, timelock::stage_src_withdrawal()), 200 + i);
            };
            if (test_time >= TEST_BASE_TIME + 40) {
                assert!(timelock::is_after_stage(&timelocks, timelock::stage_src_public_cancellation()), 300 + i);
            };
            
            i = i + 1;
        };
    }
}