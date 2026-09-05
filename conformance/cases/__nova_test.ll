; ModuleID = 'nova_module'
source_filename = "nova_module"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-darwin24.6.0"

@heap_ptr = global i64 2528
@persistent_ptr = global i64 33556960
@free_list = global i64 0
@str_literal = internal global <{ i32, i32, [28 x i8] }> <{ i32 -1000000000, i32 28, [28 x i8] c"List.at: index out of bounds" }>
@str_literal.1 = internal global <{ i32, i32, [14 x i8] }> <{ i32 -1000000000, i32 14, [14 x i8] c"list.size != 0" }>
@str_literal.2 = internal global <{ i32, i32, [14 x i8] }> <{ i32 -1000000000, i32 14, [14 x i8] c"list.size != 3" }>
@str_literal.3 = internal global <{ i32, i32, [13 x i8] }> <{ i32 -1000000000, i32 13, [13 x i8] c"list[0] != 10" }>
@str_literal.4 = internal global <{ i32, i32, [0 x i8] }> <{ i32 -1000000000, i32 0, [0 x i8] zeroinitializer }>
@str_literal.5 = internal global <{ i32, i32, [5 x i8] }> <{ i32 -1000000000, i32 5, [5 x i8] c"hello" }>
@str_literal.6 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"he" }>
@str_literal.7 = internal global <{ i32, i32, [15 x i8] }> <{ i32 -1000000000, i32 15, [15 x i8] c"startsWith fail" }>
@str_literal.8 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"lo" }>
@str_literal.9 = internal global <{ i32, i32, [24 x i8] }> <{ i32 -1000000000, i32 24, [24 x i8] c"startsWith negative fail" }>
@str_literal.10 = internal global <{ i32, i32, [13 x i8] }> <{ i32 -1000000000, i32 13, [13 x i8] c"endsWith fail" }>
@str_literal.11 = internal global <{ i32, i32, [22 x i8] }> <{ i32 -1000000000, i32 22, [22 x i8] c"endsWith negative fail" }>
@str_literal.12 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"el" }>
@str_literal.13 = internal global <{ i32, i32, [13 x i8] }> <{ i32 -1000000000, i32 13, [13 x i8] c"contains fail" }>
@str_literal.14 = internal global <{ i32, i32, [5 x i8] }> <{ i32 -1000000000, i32 5, [5 x i8] c"world" }>
@str_literal.15 = internal global <{ i32, i32, [22 x i8] }> <{ i32 -1000000000, i32 22, [22 x i8] c"contains negative fail" }>
@str_literal.16 = internal global <{ i32, i32, [1 x i8] }> <{ i32 -1000000000, i32 1, [1 x i8] c"e" }>
@str_literal.17 = internal global <{ i32, i32, [12 x i8] }> <{ i32 -1000000000, i32 12, [12 x i8] c"indexOf fail" }>
@str_literal.18 = internal global <{ i32, i32, [1 x i8] }> <{ i32 -1000000000, i32 1, [1 x i8] c"z" }>
@str_literal.19 = internal global <{ i32, i32, [21 x i8] }> <{ i32 -1000000000, i32 21, [21 x i8] c"indexOf negative fail" }>
@str_literal.20 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c"abc" }>
@str_literal.21 = internal global <{ i32, i32, [8 x i8] }> <{ i32 -1000000000, i32 8, [8 x i8] c"eql fail" }>
@str_literal.22 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c"def" }>
@str_literal.23 = internal global <{ i32, i32, [17 x i8] }> <{ i32 -1000000000, i32 17, [17 x i8] c"eql negative fail" }>
@str_literal.24 = internal global <{ i32, i32, [14 x i8] }> <{ i32 -1000000000, i32 14, [14 x i8] c"compare < fail" }>
@str_literal.25 = internal global <{ i32, i32, [14 x i8] }> <{ i32 -1000000000, i32 14, [14 x i8] c"compare > fail" }>
@str_literal.26 = internal global <{ i32, i32, [15 x i8] }> <{ i32 -1000000000, i32 15, [15 x i8] c"compare == fail" }>
@str_literal.27 = internal global <{ i32, i32, [4 x i8] }> <{ i32 -1000000000, i32 4, [4 x i8] c"1234" }>
@str_literal.28 = internal global <{ i32, i32, [22 x i8] }> <{ i32 -1000000000, i32 22, [22 x i8] c"parseI64 positive fail" }>
@str_literal.29 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c"-56" }>
@str_literal.30 = internal global <{ i32, i32, [22 x i8] }> <{ i32 -1000000000, i32 22, [22 x i8] c"parseI64 negative fail" }>
@str_literal.31 = internal global <{ i32, i32, [17 x i8] }> <{ i32 -1000000000, i32 17, [17 x i8] c"parseLong ok fail" }>
@str_literal.32 = internal global <{ i32, i32, [18 x i8] }> <{ i32 -1000000000, i32 18, [18 x i8] c"parseLong neg fail" }>
@str_literal.33 = internal global <{ i32, i32, [35 x i8] }> <{ i32 -1000000000, i32 35, [35 x i8] c"parseLong empty should be undefined" }>
@str_literal.34 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c"12x" }>
@str_literal.35 = internal global <{ i32, i32, [46 x i8] }> <{ i32 -1000000000, i32 46, [46 x i8] c"parseLong trailing garbage should be undefined" }>
@str_literal.36 = internal global <{ i32, i32, [1 x i8] }> <{ i32 -1000000000, i32 1, [1 x i8] c"+" }>
@str_literal.37 = internal global <{ i32, i32, [39 x i8] }> <{ i32 -1000000000, i32 39, [39 x i8] c"parseLong lone sign should be undefined" }>
@str_literal.38 = internal global <{ i32, i32, [20 x i8] }> <{ i32 -1000000000, i32 20, [20 x i8] c"99999999999999999999" }>
@str_literal.39 = internal global <{ i32, i32, [38 x i8] }> <{ i32 -1000000000, i32 38, [38 x i8] c"parseLong overflow should be undefined" }>
@str_literal.40 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"42" }>
@str_literal.41 = internal global <{ i32, i32, [16 x i8] }> <{ i32 -1000000000, i32 16, [16 x i8] c"parseInt ok fail" }>
@str_literal.42 = internal global <{ i32, i32, [10 x i8] }> <{ i32 -1000000000, i32 10, [10 x i8] c"3000000000" }>
@str_literal.43 = internal global <{ i32, i32, [45 x i8] }> <{ i32 -1000000000, i32 45, [45 x i8] c"parseInt out-of-i32-range should be undefined" }>
@str_literal.44 = internal global <{ i32, i32, [40 x i8] }> <{ i32 -1000000000, i32 40, [40 x i8] c"parseInt non-numeric should be undefined" }>
@str_literal.45 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c"1e3" }>
@str_literal.46 = internal global <{ i32, i32, [25 x i8] }> <{ i32 -1000000000, i32 25, [25 x i8] c"parseDouble exponent fail" }>
@str_literal.47 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c"2.5" }>
@str_literal.48 = internal global <{ i32, i32, [21 x i8] }> <{ i32 -1000000000, i32 21, [21 x i8] c"parseDouble frac fail" }>
@str_literal.49 = internal global <{ i32, i32, [6 x i8] }> <{ i32 -1000000000, i32 6, [6 x i8] c"-1.5e2" }>
@str_literal.50 = internal global <{ i32, i32, [24 x i8] }> <{ i32 -1000000000, i32 24, [24 x i8] c"parseDouble neg exp fail" }>
@str_literal.51 = internal global <{ i32, i32, [37 x i8] }> <{ i32 -1000000000, i32 37, [37 x i8] c"parseDouble empty should be undefined" }>
@str_literal.52 = internal global <{ i32, i32, [5 x i8] }> <{ i32 -1000000000, i32 5, [5 x i8] c"1.2.3" }>
@str_literal.53 = internal global <{ i32, i32, [42 x i8] }> <{ i32 -1000000000, i32 42, [42 x i8] c"parseDouble double-dot should be undefined" }>
@str_literal.54 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"1e" }>
@str_literal.55 = internal global <{ i32, i32, [44 x i8] }> <{ i32 -1000000000, i32 44, [44 x i8] c"parseDouble dangling exp should be undefined" }>
@str_literal.56 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"5x" }>
@str_literal.57 = internal global <{ i32, i32, [48 x i8] }> <{ i32 -1000000000, i32 48, [48 x i8] c"parseDouble trailing garbage should be undefined" }>
@str_literal.58 = internal global <{ i32, i32, [24 x i8] }> <{ i32 -1000000000, i32 24, [24 x i8] c"Expected true, got false" }>
@str_literal.59 = internal global <{ i32, i32, [24 x i8] }> <{ i32 -1000000000, i32 24, [24 x i8] c"Expected false, got true" }>
@str_literal.60 = internal global <{ i32, i32, [9 x i8] }> <{ i32 -1000000000, i32 9, [9 x i8] c"Expected " }>
@str_literal.61 = internal global <{ i32, i32, [6 x i8] }> <{ i32 -1000000000, i32 6, [6 x i8] c", got " }>
@str_literal.62 = internal global <{ i32, i32, [37 x i8] }> <{ i32 -1000000000, i32 37, [37 x i8] c"Expected values to differ, both were " }>
@str_literal.63 = internal global <{ i32, i32, [10 x i8] }> <{ i32 -1000000000, i32 10, [10 x i8] c"Expected \22" }>
@str_literal.64 = internal global <{ i32, i32, [8 x i8] }> <{ i32 -1000000000, i32 8, [8 x i8] c"\22, got \22" }>
@str_literal.65 = internal global <{ i32, i32, [1 x i8] }> <{ i32 -1000000000, i32 1, [1 x i8] c"\22" }>
@str_literal.66 = internal global <{ i32, i32, [39 x i8] }> <{ i32 -1000000000, i32 39, [39 x i8] c"Expected strings to differ, both were \22" }>
@str_literal.67 = internal global <{ i32, i32, [14 x i8] }> <{ i32 -1000000000, i32 14, [14 x i8] c"\22 to contain \22" }>
@str_literal.68 = internal global <{ i32, i32, [30 x i8] }> <{ i32 -1000000000, i32 30, [30 x i8] c"Expected non-zero value, got 0" }>
@str_literal.69 = internal global <{ i32, i32, [16 x i8] }> <{ i32 -1000000000, i32 16, [16 x i8] c"Expected 0, got " }>
@str_literal.70 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c" > " }>
@str_literal.71 = internal global <{ i32, i32, [4 x i8] }> <{ i32 -1000000000, i32 4, [4 x i8] c" >= " }>
@str_literal.72 = internal global <{ i32, i32, [3 x i8] }> <{ i32 -1000000000, i32 3, [3 x i8] c" < " }>
@str_literal.73 = internal global <{ i32, i32, [4 x i8] }> <{ i32 -1000000000, i32 4, [4 x i8] c" <= " }>
@str_literal.74 = internal global <{ i32, i32, [1 x i8] }> <{ i32 -1000000000, i32 1, [1 x i8] c" " }>
@str_literal.75 = internal global <{ i32, i32, [11 x i8] }> <{ i32 -1000000000, i32 11, [11 x i8] c"hello world" }>
@str_literal.76 = internal global <{ i32, i32, [11 x i8] }> <{ i32 -1000000000, i32 11, [11 x i8] c"not found: " }>
@str_literal.77 = internal global <{ i32, i32, [16 x i8] }> <{ i32 -1000000000, i32 16, [16 x i8] c"timed out after " }>
@str_literal.78 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"ms" }>
@str_literal.79 = internal global <{ i32, i32, [7 x i8] }> <{ i32 -1000000000, i32 7, [7 x i8] c"unknown" }>
@str_literal.80 = internal global <{ i32, i32, [7 x i8] }> <{ i32 -1000000000, i32 7, [7 x i8] c"missing" }>
@str_literal.81 = internal global <{ i32, i32, [4 x i8] }> <{ i32 -1000000000, i32 4, [4 x i8] c"slow" }>
@str_literal.82 = internal global <{ i32, i32, [9 x i8] }> <{ i32 -1000000000, i32 9, [9 x i8] c"data for " }>
@str_literal.83 = internal global <{ i32, i32, [14 x i8] }> <{ i32 -1000000000, i32 14, [14 x i8] c"data for user1" }>
@str_literal.84 = internal global <{ i32, i32, [18 x i8] }> <{ i32 -1000000000, i32 18, [18 x i8] c"not found: missing" }>
@str_literal.85 = internal global <{ i32, i32, [21 x i8] }> <{ i32 -1000000000, i32 21, [21 x i8] c"timed out after 500ms" }>
@str_literal.86 = internal global <{ i32, i32, [1 x i8] }> <{ i32 -1000000000, i32 1, [1 x i8] c"!" }>
@str_literal.87 = internal global <{ i32, i32, [12 x i8] }> <{ i32 -1000000000, i32 12, [12 x i8] c"data for ok!" }>
@str_literal.88 = internal global <{ i32, i32, [20 x i8] }> <{ i32 -1000000000, i32 20, [20 x i8] c"Running 8 test(s)..." }>
@str_literal.89 = internal global <{ i32, i32, [9 x i8] }> <{ i32 -1000000000, i32 9, [9 x i8] c"test_list" }>
@str_literal.90 = internal global <{ i32, i32, [17 x i8] }> <{ i32 -1000000000, i32 17, [17 x i8] c"  PASS  test_list" }>
@str_literal.91 = internal global <{ i32, i32, [17 x i8] }> <{ i32 -1000000000, i32 17, [17 x i8] c"  FAIL  test_list" }>
@str_literal.92 = internal global <{ i32, i32, [8 x i8] }> <{ i32 -1000000000, i32 8, [8 x i8] c"        " }>
@str_literal.93 = internal global <{ i32, i32, [19 x i8] }> <{ i32 -1000000000, i32 19, [19 x i8] c"test_string_helpers" }>
@str_literal.94 = internal global <{ i32, i32, [27 x i8] }> <{ i32 -1000000000, i32 27, [27 x i8] c"  PASS  test_string_helpers" }>
@str_literal.95 = internal global <{ i32, i32, [27 x i8] }> <{ i32 -1000000000, i32 27, [27 x i8] c"  FAIL  test_string_helpers" }>
@str_literal.96 = internal global <{ i32, i32, [21 x i8] }> <{ i32 -1000000000, i32 21, [21 x i8] c"test_assert_mechanics" }>
@str_literal.97 = internal global <{ i32, i32, [29 x i8] }> <{ i32 -1000000000, i32 29, [29 x i8] c"  PASS  test_assert_mechanics" }>
@str_literal.98 = internal global <{ i32, i32, [29 x i8] }> <{ i32 -1000000000, i32 29, [29 x i8] c"  FAIL  test_assert_mechanics" }>
@str_literal.99 = internal global <{ i32, i32, [19 x i8] }> <{ i32 -1000000000, i32 19, [19 x i8] c"test_string_builder" }>
@str_literal.100 = internal global <{ i32, i32, [27 x i8] }> <{ i32 -1000000000, i32 27, [27 x i8] c"  PASS  test_string_builder" }>
@str_literal.101 = internal global <{ i32, i32, [27 x i8] }> <{ i32 -1000000000, i32 27, [27 x i8] c"  FAIL  test_string_builder" }>
@str_literal.102 = internal global <{ i32, i32, [22 x i8] }> <{ i32 -1000000000, i32 22, [22 x i8] c"test_ok_passes_through" }>
@str_literal.103 = internal global <{ i32, i32, [30 x i8] }> <{ i32 -1000000000, i32 30, [30 x i8] c"  PASS  test_ok_passes_through" }>
@str_literal.104 = internal global <{ i32, i32, [30 x i8] }> <{ i32 -1000000000, i32 30, [30 x i8] c"  FAIL  test_ok_passes_through" }>
@str_literal.105 = internal global <{ i32, i32, [29 x i8] }> <{ i32 -1000000000, i32 29, [29 x i8] c"test_first_variant_dispatches" }>
@str_literal.106 = internal global <{ i32, i32, [37 x i8] }> <{ i32 -1000000000, i32 37, [37 x i8] c"  PASS  test_first_variant_dispatches" }>
@str_literal.107 = internal global <{ i32, i32, [37 x i8] }> <{ i32 -1000000000, i32 37, [37 x i8] c"  FAIL  test_first_variant_dispatches" }>
@str_literal.108 = internal global <{ i32, i32, [30 x i8] }> <{ i32 -1000000000, i32 30, [30 x i8] c"test_second_variant_dispatches" }>
@str_literal.109 = internal global <{ i32, i32, [38 x i8] }> <{ i32 -1000000000, i32 38, [38 x i8] c"  PASS  test_second_variant_dispatches" }>
@str_literal.110 = internal global <{ i32, i32, [38 x i8] }> <{ i32 -1000000000, i32 38, [38 x i8] c"  FAIL  test_second_variant_dispatches" }>
@str_literal.111 = internal global <{ i32, i32, [29 x i8] }> <{ i32 -1000000000, i32 29, [29 x i8] c"test_try_propagates_exception" }>
@str_literal.112 = internal global <{ i32, i32, [37 x i8] }> <{ i32 -1000000000, i32 37, [37 x i8] c"  PASS  test_try_propagates_exception" }>
@str_literal.113 = internal global <{ i32, i32, [37 x i8] }> <{ i32 -1000000000, i32 37, [37 x i8] c"  FAIL  test_try_propagates_exception" }>
@str_literal.114 = internal global <{ i32, i32, [9 x i8] }> <{ i32 -1000000000, i32 9, [9 x i8] c"Results: " }>
@str_literal.115 = internal global <{ i32, i32, [9 x i8] }> <{ i32 -1000000000, i32 9, [9 x i8] c" passed, " }>
@str_literal.116 = internal global <{ i32, i32, [9 x i8] }> <{ i32 -1000000000, i32 9, [9 x i8] c" failed, " }>
@str_literal.117 = internal global <{ i32, i32, [6 x i8] }> <{ i32 -1000000000, i32 6, [6 x i8] c" total" }>
@str_literal.118 = internal global <{ i32, i32, [4 x i8] }> <{ i32 -1000000000, i32 4, [4 x i8] c"true" }>
@str_literal.119 = internal global <{ i32, i32, [5 x i8] }> <{ i32 -1000000000, i32 5, [5 x i8] c"false" }>
@trap_msg = private unnamed_addr constant [25 x i8] c"integer division by zero\00", align 1
@trap_msg.120 = private unnamed_addr constant [41 x i8] c"integer division overflow (INT_MIN / -1)\00", align 1
@trap_msg.121 = private unnamed_addr constant [25 x i8] c"integer division by zero\00", align 1
@trap_msg.122 = private unnamed_addr constant [41 x i8] c"integer division overflow (INT_MIN / -1)\00", align 1
@str_literal.123 = internal global <{ i32, i32, [5 x i8] }> <{ i32 -1000000000, i32 5, [5 x i8] c"user1" }>
@str_literal.124 = internal global <{ i32, i32, [2 x i8] }> <{ i32 -1000000000, i32 2, [2 x i8] c"ok" }>

declare i64 @nova_i64_to_string(i64)

declare i64 @nova_f64_to_string(double)

declare ptr @nova_ieee_le_to_str(ptr, i32)

declare i64 @nova_f64_bits(double)

declare double @nova_pg_be_f64(i64, i32)

declare i64 @nova_pg_be_i64(i64, i32)

declare i32 @nova_html_find_meta(i64, i32, i32)

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.sqrt.f64(double) #0

declare i64 @nova_bool_to_string(i64)

declare i64 @nova_decimal_from_string(ptr)

declare i64 @nova_decimal_to_string(i64)

declare i64 @nova_decimal_add(i64, i64)

declare i64 @nova_decimal_sub(i64, i64)

declare i64 @nova_decimal_mul(i64, i64)

declare i64 @nova_decimal_div(i64, i64)

declare i64 @nova_decimal_mod(i64, i64)

declare i64 @nova_decimal_cmp(i64, i64)

declare i64 @nova_decimal_from_int(i64)

declare i64 @nova_decimal_to_int(i64)

declare i64 @nova_decimal_from_string_n(ptr, i64)

declare i64 @nova_invoke_str_closure(i64, i64)

declare void @nova_invoke_void_closure(i64)

declare i32 @printf(ptr, ...)

declare i32 @puts(ptr)

declare void @nova_log_string(ptr)

declare void @nova_log_info(ptr)

declare void @nova_log_debug(ptr)

declare void @nova_log_err(ptr)

declare ptr @malloc(i64)

declare i64 @nova_time_now()

declare i64 @nova_time_now_ns()

declare i64 @nova_get_stacktrace()

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare token @llvm.coro.id(i32, ptr readnone, ptr readonly captures(none), ptr) #1

; Function Attrs: nounwind memory(none)
declare i64 @llvm.coro.size.i64() #2

; Function Attrs: nounwind
declare ptr @llvm.coro.begin(token, ptr writeonly) #3

; Function Attrs: nounwind
declare i8 @llvm.coro.suspend(token, i1) #3

; Function Attrs: nounwind
declare i1 @llvm.coro.end(ptr, i1, token) #3

; Function Attrs: nounwind memory(argmem: read)
declare ptr @llvm.coro.free(token, ptr readonly captures(none)) #4

declare void @llvm.coro.resume(ptr)

declare void @llvm.coro.destroy(ptr)

; Function Attrs: nounwind memory(argmem: readwrite)
declare i1 @llvm.coro.done(ptr readonly captures(none)) #5

; Function Attrs: nounwind memory(none)
declare ptr @llvm.coro.promise(ptr captures(none), i32, i1) #2

declare i64 @nova_coro_alloc(i64)

declare void @nova_coro_free(i64)

declare void @nova_sched_schedule(i64)

declare void @nova_sched_schedule_detached(i64)

declare i64 @nova_sched_next()

declare void @nova_run()

declare void @nova_coro_release(i64)

declare void @nova_run_root(i64)

declare void @nova_await_timer(i64, i64)

declare void @nova_register_waiter(i64, i64)

declare i64 @nova_await_future(i64, i64)

declare i64 @nova_chan_new(i64)

declare void @nova_chan_send(i64, i64)

declare i64 @nova_chan_recv(i64, i64, ptr)

declare void @nova_chan_free(i64)

declare void @nova_io_recv_async(i64, i64, i64, i64)

declare void @nova_io_accept_async(i64, i64)

declare i64 @nova_io_take_result(i64)

declare i64 @nova_aserver_listen(i64)

declare i64 @nova_aserver_listen_addr(i64, i64)

declare void @nova_aaccept(i64, i64)

declare void @nova_aconnect(i64, i64, i64)

declare void @nova_arecv(i64, i64, i64, i64)

declare void @nova_arecv_deadline(i64, i64, i64, i64, i64)

declare void @nova_asend(i64, i64, i64)

declare void @nova_aclose(i64)

declare void @nova_coro_hold_arg(i64, i64, ptr)

declare i64 @nova_when_any(i64, i64, i64)

declare i64 @nova_when_any_deadline(i64, i64, i64, i64)

declare i32 @nova_close(i32)

declare void @nova_test_reset()

declare void @nova_optional_deref_fail(ptr)

declare void @nova_panic(ptr)

declare void @nova_panic_cstr(ptr)

declare void @nova_test_begin(ptr)

declare void @nova_test_fail(ptr)

declare i32 @nova_test_did_fail()

declare ptr @nova_test_fail_message()

declare i64 @nova_arg_count()

declare i64 @nova_arg_at(i64)

declare void @nova_getrandom(ptr, i64)

declare ptr @nova_process_spawn(ptr, ptr)

declare ptr @nova_process_spawn_isolated(ptr, ptr, i64, ptr, ptr, i32, i32, i32)

declare i32 @nova_process_write_stdin(ptr, ptr)

declare i32 @nova_process_read_stdout(ptr, ptr, i32)

declare i32 @nova_process_wait(ptr)

declare i64 @nova_process_pid(ptr)

declare i32 @nova_process_try_wait(ptr)

declare i32 @nova_process_kill(ptr, i32)

declare void @nova_process_free(ptr)

declare ptr @nova_fs_watcher_create(ptr)

declare ptr @nova_fs_watcher_next_event(ptr)

declare void @nova_fs_watcher_free_event(ptr)

declare void @nova_fs_watcher_close(ptr)

declare void @nova_exit(i32)

declare i64 @nova_arc_audit_report()

declare void @nova_bytes_free(i64)

declare i64 @nova_channel_create(i32)

declare void @nova_channel_send(i64, i64)

declare i64 @nova_channel_recv(i64)

declare i64 @nova_mutex_create()

declare i64 @nova_thread_id()

declare i64 @nova_worker_count()

declare i64 @nova_spin_create()

declare void @nova_spin_lock(i64)

declare void @nova_spin_unlock(i64)

declare void @nova_pin_next_coro(i64)

declare void @nova_trace_msg(i64)

declare i64 @nova_trace_enabled()

declare void @nova_trace_kv(i64, i64)

declare i64 @nova_reactor_resume(i64)

declare void @nova_run_reactors(i64, i64)

declare void @nova_reactor_detach(i64)

declare void @nova_reactor_set_current(i64)

declare i64 @nova_reactor_current()

declare void @nova_reactor_set_timer(i64, i64)

declare void @nova_reactor_cancel_timer(i64)

declare void @nova_reactor_batch_begin()

declare i64 @nova_mono_ms()

declare void @nova_reactor_wake_register(i64, i64)

declare void @nova_reactor_post(i64, i64)

declare i64 @nova_reactor_drain_one(i64)

declare i64 @nova_evfilt_user()

declare void @nova_hold_all_reactors()

declare void @nova_mutex_lock(i64)

declare void @nova_mutex_unlock(i64)

declare i64 @nova_condvar_create()

declare void @nova_condvar_wait(i64, i64)

declare void @nova_condvar_signal(i64)

declare void @nova_condvar_broadcast(i64)

declare i64 @nova_rwlock_create()

declare void @nova_rwlock_acquire_read(i64)

declare void @nova_rwlock_release_read(i64)

declare void @nova_rwlock_acquire_write(i64)

declare void @nova_rwlock_release_write(i64)

declare i64 @nova_bytes_alloc_persistent(i64)

declare void @nova_channel_destroy(i64)

declare void @nova_mutex_destroy(i64)

declare void @nova_condvar_destroy(i64)

declare void @nova_rwlock_destroy(i64)

declare void @nova_retain(i64)

declare void @nova_release(i64, ptr)

declare ptr @nova_ffi_to_cstr(ptr)

declare ptr @nova_ffi_from_cstr(ptr)

declare void @nova_ffi_free_cstr(ptr, ptr)

define internal void @RawBuffer_init(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %capElems = alloca i64, align 8
  store i64 %1, ptr %capElems, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %2 = load i64, ptr %capElems, align 8
  %cmptmp = icmp sle i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  br label %ifcont

else:                                             ; preds = %entry
  %3 = load i64, ptr %capElems, align 8
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  %ifphi = phi i64 [ 1, %then ], [ %3, %else ]
  store i64 %ifphi, ptr %c, align 8
  %4 = load i64, ptr %c, align 8
  %multmp = mul i64 %4, 8
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext)
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  store i64 %alloc_tmp, ptr %field_ptr, align 8
  %6 = load i64, ptr %c, align 8
  %7 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %7, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %trunc = trunc i64 %6 to i32
  store i32 %trunc, ptr %field_ptr2, align 4
  %8 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %8, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  store i32 0, ptr %field_ptr4, align 4
  ret void
}

define void @RawBuffer_i32_init(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %capElems = alloca i64, align 8
  store i64 %1, ptr %capElems, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %2 = load i64, ptr %capElems, align 8
  %cmptmp = icmp sle i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  br label %ifcont

else:                                             ; preds = %entry
  %3 = load i64, ptr %capElems, align 8
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  %ifphi = phi i64 [ 1, %then ], [ %3, %else ]
  store i64 %ifphi, ptr %c, align 8
  %4 = load i64, ptr %c, align 8
  %multmp = mul i64 %4, 8
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext)
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  store i64 %alloc_tmp, ptr %field_ptr, align 8
  %6 = load i64, ptr %c, align 8
  %7 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %7, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %trunc = trunc i64 %6 to i32
  store i32 %trunc, ptr %field_ptr2, align 4
  %8 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %8, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  store i32 0, ptr %field_ptr4, align 4
  ret void
}

define void @RawBuffer_string_init(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %capElems = alloca i64, align 8
  store i64 %1, ptr %capElems, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %2 = load i64, ptr %capElems, align 8
  %cmptmp = icmp sle i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  br label %ifcont

else:                                             ; preds = %entry
  %3 = load i64, ptr %capElems, align 8
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  %ifphi = phi i64 [ 1, %then ], [ %3, %else ]
  store i64 %ifphi, ptr %c, align 8
  %4 = load i64, ptr %c, align 8
  %multmp = mul i64 %4, 8
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext)
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  store i64 %alloc_tmp, ptr %field_ptr, align 8
  %6 = load i64, ptr %c, align 8
  %7 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %7, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %trunc = trunc i64 %6 to i32
  store i32 %trunc, ptr %field_ptr2, align 4
  %8 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %8, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  store i32 0, ptr %field_ptr4, align 4
  ret void
}

define internal i64 @RawBuffer_capacity(i64 %0) {
entry:
  %1 = add i64 %0, 8
  %2 = inttoptr i64 %1 to ptr
  %3 = load i32, ptr %2, align 4
  %sext = sext i32 %3 to i64
  ret i64 %sext
}

define i64 @RawBuffer_i32_capacity(i64 %0) {
entry:
  %1 = add i64 %0, 8
  %2 = inttoptr i64 %1 to ptr
  %3 = load i32, ptr %2, align 4
  %sext = sext i32 %3 to i64
  ret i64 %sext
}

define i64 @RawBuffer_string_capacity(i64 %0) {
entry:
  %1 = add i64 %0, 8
  %2 = inttoptr i64 %1 to ptr
  %3 = load i32, ptr %2, align 4
  %sext = sext i32 %3 to i64
  ret i64 %sext
}

define internal i64 @RawBuffer_count(i64 %0) {
entry:
  %1 = add i64 %0, 12
  %2 = inttoptr i64 %1 to ptr
  %3 = load i32, ptr %2, align 4
  %sext = sext i32 %3 to i64
  ret i64 %sext
}

define i64 @RawBuffer_i32_count(i64 %0) {
entry:
  %1 = add i64 %0, 12
  %2 = inttoptr i64 %1 to ptr
  %3 = load i32, ptr %2, align 4
  %sext = sext i32 %3 to i64
  ret i64 %sext
}

define i64 @RawBuffer_string_count(i64 %0) {
entry:
  %1 = add i64 %0, 12
  %2 = inttoptr i64 %1 to ptr
  %3 = load i32, ptr %2, align 4
  %sext = sext i32 %3 to i64
  ret i64 %sext
}

define internal i64 @RawBuffer_base(i64 %0) {
entry:
  %1 = add i64 %0, 0
  %2 = inttoptr i64 %1 to ptr
  %3 = load i64, ptr %2, align 8
  ret i64 %3
}

define i64 @RawBuffer_i32_base(i64 %0) {
entry:
  %1 = add i64 %0, 0
  %2 = inttoptr i64 %1 to ptr
  %3 = load i64, ptr %2, align 8
  ret i64 %3
}

define i64 @RawBuffer_string_base(i64 %0) {
entry:
  %1 = add i64 %0, 0
  %2 = inttoptr i64 %1 to ptr
  %3 = load i64, ptr %2, align 8
  ret i64 %3
}

define internal void @RawBuffer_fill(i64 %0, i64 %1) {
entry:
  %2 = add i64 %0, 12
  %3 = inttoptr i64 %2 to ptr
  %trunc = trunc i64 %1 to i32
  store i32 %trunc, ptr %3, align 4
  ret void
}

define void @RawBuffer_i32_fill(i64 %0, i64 %1) {
entry:
  %2 = add i64 %0, 12
  %3 = inttoptr i64 %2 to ptr
  %trunc = trunc i64 %1 to i32
  store i32 %trunc, ptr %3, align 4
  ret void
}

define void @RawBuffer_string_fill(i64 %0, i64 %1) {
entry:
  %2 = add i64 %0, 12
  %3 = inttoptr i64 %2 to ptr
  %trunc = trunc i64 %1 to i32
  store i32 %trunc, ptr %3, align 4
  ret void
}

define internal i64 @RawBuffer_slot(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i64, ptr %field_ptr, align 8
  %3 = load i64, ptr %i, align 8
  %multmp = mul i64 %3, 8
  %addtmp = add i64 %field_val, %multmp
  ret i64 %addtmp
}

define i64 @RawBuffer_i32_slot(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i64, ptr %field_ptr, align 8
  %3 = load i64, ptr %i, align 8
  %multmp = mul i64 %3, 8
  %addtmp = add i64 %field_val, %multmp
  ret i64 %addtmp
}

define i64 @RawBuffer_string_slot(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i64, ptr %field_ptr, align 8
  %3 = load i64, ptr %i, align 8
  %multmp = mul i64 %3, 8
  %addtmp = add i64 %field_val, %multmp
  ret i64 %addtmp
}

define internal void @RawBuffer_push(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %nc = alloca i64, align 8
  store i64 0, ptr %nc, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %3 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %3, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %cmptmp = icmp sge i64 %sext, %sext4
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %4, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %field_val7 = load i32, ptr %field_ptr6, align 4
  %sext8 = sext i32 %field_val7 to i64
  %cmptmp9 = icmp slt i64 %sext8, 1
  %zexttmp10 = zext i1 %cmptmp9 to i64
  %ifcond11 = icmp ne i64 %zexttmp10, 0
  br i1 %ifcond11, label %then12, label %else

ifcont:                                           ; preds = %ifcont13, %entry
  %5 = load i64, ptr %self, align 8
  %6 = load i64, ptr %self, align 8
  %field_addr18 = add i64 %6, 12
  %field_ptr19 = inttoptr i64 %field_addr18 to ptr
  %field_val20 = load i32, ptr %field_ptr19, align 4
  %sext21 = sext i32 %field_val20 to i64
  %calltmp = call i64 @RawBuffer_slot(i64 %5, i64 %sext21)
  %7 = load i64, ptr %value, align 8
  %we_sp = inttoptr i64 %calltmp to ptr
  store i64 %7, ptr %we_sp, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr22 = add i64 %8, 12
  %field_ptr23 = inttoptr i64 %field_addr22 to ptr
  %field_val24 = load i32, ptr %field_ptr23, align 4
  %sext25 = sext i32 %field_val24 to i64
  %addtmp = add i64 %sext25, 1
  %int_trunc26 = trunc i64 %addtmp to i32
  %int_sext27 = sext i32 %int_trunc26 to i64
  %9 = load i64, ptr %self, align 8
  %field_addr28 = add i64 %9, 12
  %field_ptr29 = inttoptr i64 %field_addr28 to ptr
  %trunc = trunc i64 %int_sext27 to i32
  store i32 %trunc, ptr %field_ptr29, align 4
  ret void

then12:                                           ; preds = %then
  br label %ifcont13

else:                                             ; preds = %then
  %10 = load i64, ptr %self, align 8
  %field_addr14 = add i64 %10, 8
  %field_ptr15 = inttoptr i64 %field_addr14 to ptr
  %field_val16 = load i32, ptr %field_ptr15, align 4
  %sext17 = sext i32 %field_val16 to i64
  %multmp = mul i64 %sext17, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  br label %ifcont13

ifcont13:                                         ; preds = %else, %then12
  %ifphi = phi i64 [ 1, %then12 ], [ %int_sext, %else ]
  store i64 %ifphi, ptr %nc, align 8
  %11 = load i64, ptr %self, align 8
  %12 = load i64, ptr %nc, align 8
  call void @RawBuffer_reserveExact(i64 %11, i64 %12)
  br label %ifcont
}

define void @RawBuffer_i32_push(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %nc = alloca i64, align 8
  store i64 0, ptr %nc, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %3 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %3, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %cmptmp = icmp sge i64 %sext, %sext4
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %4, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %field_val7 = load i32, ptr %field_ptr6, align 4
  %sext8 = sext i32 %field_val7 to i64
  %cmptmp9 = icmp slt i64 %sext8, 1
  %zexttmp10 = zext i1 %cmptmp9 to i64
  %ifcond11 = icmp ne i64 %zexttmp10, 0
  br i1 %ifcond11, label %then12, label %else

ifcont:                                           ; preds = %ifcont13, %entry
  %5 = load i64, ptr %self, align 8
  %6 = load i64, ptr %self, align 8
  %field_addr18 = add i64 %6, 12
  %field_ptr19 = inttoptr i64 %field_addr18 to ptr
  %field_val20 = load i32, ptr %field_ptr19, align 4
  %sext21 = sext i32 %field_val20 to i64
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %5, i64 %sext21)
  %7 = load i64, ptr %value, align 8
  %we_sp = inttoptr i64 %calltmp to ptr
  store i64 %7, ptr %we_sp, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr22 = add i64 %8, 12
  %field_ptr23 = inttoptr i64 %field_addr22 to ptr
  %field_val24 = load i32, ptr %field_ptr23, align 4
  %sext25 = sext i32 %field_val24 to i64
  %addtmp = add i64 %sext25, 1
  %int_trunc26 = trunc i64 %addtmp to i32
  %int_sext27 = sext i32 %int_trunc26 to i64
  %9 = load i64, ptr %self, align 8
  %field_addr28 = add i64 %9, 12
  %field_ptr29 = inttoptr i64 %field_addr28 to ptr
  %trunc = trunc i64 %int_sext27 to i32
  store i32 %trunc, ptr %field_ptr29, align 4
  ret void

then12:                                           ; preds = %then
  br label %ifcont13

else:                                             ; preds = %then
  %10 = load i64, ptr %self, align 8
  %field_addr14 = add i64 %10, 8
  %field_ptr15 = inttoptr i64 %field_addr14 to ptr
  %field_val16 = load i32, ptr %field_ptr15, align 4
  %sext17 = sext i32 %field_val16 to i64
  %multmp = mul i64 %sext17, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  br label %ifcont13

ifcont13:                                         ; preds = %else, %then12
  %ifphi = phi i64 [ 1, %then12 ], [ %int_sext, %else ]
  store i64 %ifphi, ptr %nc, align 8
  %11 = load i64, ptr %self, align 8
  %12 = load i64, ptr %nc, align 8
  call void @RawBuffer_i32_reserveExact(i64 %11, i64 %12)
  br label %ifcont
}

define void @RawBuffer_string_push(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %nc = alloca i64, align 8
  store i64 0, ptr %nc, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %3 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %3, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %cmptmp = icmp sge i64 %sext, %sext4
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %4, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %field_val7 = load i32, ptr %field_ptr6, align 4
  %sext8 = sext i32 %field_val7 to i64
  %cmptmp9 = icmp slt i64 %sext8, 1
  %zexttmp10 = zext i1 %cmptmp9 to i64
  %ifcond11 = icmp ne i64 %zexttmp10, 0
  br i1 %ifcond11, label %then12, label %else

ifcont:                                           ; preds = %ifcont13, %entry
  %5 = load i64, ptr %self, align 8
  %6 = load i64, ptr %self, align 8
  %field_addr18 = add i64 %6, 12
  %field_ptr19 = inttoptr i64 %field_addr18 to ptr
  %field_val20 = load i32, ptr %field_ptr19, align 4
  %sext21 = sext i32 %field_val20 to i64
  %calltmp = call i64 @RawBuffer_string_slot(i64 %5, i64 %sext21)
  %7 = load i64, ptr %value, align 8
  call void @nova_retain(i64 %7)
  %we_sp = inttoptr i64 %calltmp to ptr
  store i64 %7, ptr %we_sp, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr22 = add i64 %8, 12
  %field_ptr23 = inttoptr i64 %field_addr22 to ptr
  %field_val24 = load i32, ptr %field_ptr23, align 4
  %sext25 = sext i32 %field_val24 to i64
  %addtmp = add i64 %sext25, 1
  %int_trunc26 = trunc i64 %addtmp to i32
  %int_sext27 = sext i32 %int_trunc26 to i64
  %9 = load i64, ptr %self, align 8
  %field_addr28 = add i64 %9, 12
  %field_ptr29 = inttoptr i64 %field_addr28 to ptr
  %trunc = trunc i64 %int_sext27 to i32
  store i32 %trunc, ptr %field_ptr29, align 4
  ret void

then12:                                           ; preds = %then
  br label %ifcont13

else:                                             ; preds = %then
  %10 = load i64, ptr %self, align 8
  %field_addr14 = add i64 %10, 8
  %field_ptr15 = inttoptr i64 %field_addr14 to ptr
  %field_val16 = load i32, ptr %field_ptr15, align 4
  %sext17 = sext i32 %field_val16 to i64
  %multmp = mul i64 %sext17, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  br label %ifcont13

ifcont13:                                         ; preds = %else, %then12
  %ifphi = phi i64 [ 1, %then12 ], [ %int_sext, %else ]
  store i64 %ifphi, ptr %nc, align 8
  %11 = load i64, ptr %self, align 8
  %12 = load i64, ptr %nc, align 8
  call void @RawBuffer_string_reserveExact(i64 %11, i64 %12)
  br label %ifcont
}

define internal i64 @RawBuffer_at(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_slot(i64 %2, i64 %3)
  %we_lp = inttoptr i64 %calltmp to ptr
  %we_lv = load i64, ptr %we_lp, align 8
  ret i64 %we_lv
}

define i64 @RawBuffer_i32_at(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %2, i64 %3)
  %we_lp = inttoptr i64 %calltmp to ptr
  %we_lv = load i64, ptr %we_lp, align 8
  ret i64 %we_lv
}

define i64 @RawBuffer_string_at(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_string_slot(i64 %2, i64 %3)
  %we_lp = inttoptr i64 %calltmp to ptr
  %we_lv = load i64, ptr %we_lp, align 8
  call void @nova_retain(i64 %we_lv)
  store i64 %we_lv, ptr %tmp_slot, align 8
  ret i64 %we_lv
}

define internal void @RawBuffer_set(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %value, align 8
  %we_sp = inttoptr i64 %calltmp to ptr
  store i64 %5, ptr %we_sp, align 8
  ret void
}

define void @RawBuffer_i32_set(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %value, align 8
  %we_sp = inttoptr i64 %calltmp to ptr
  store i64 %5, ptr %we_sp, align 8
  ret void
}

define void @RawBuffer_string_set(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_string_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %value, align 8
  call void @nova_retain(i64 %5)
  %we_dp = inttoptr i64 %calltmp to ptr
  %we_dv = load i64, ptr %we_dp, align 8
  call void @nova_release(i64 %we_dv, ptr null)
  %we_sp = inttoptr i64 %calltmp to ptr
  store i64 %5, ptr %we_sp, align 8
  ret void
}

define internal i64 @RawBuffer_pop(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp eq i64 %sext, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %subtmp = sub i64 %sext4, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %3 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %3, 12
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %int_sext to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %4 = load i64, ptr %self, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %5, 12
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load i32, ptr %field_ptr8, align 4
  %sext10 = sext i32 %field_val9 to i64
  %calltmp = call i64 @RawBuffer_slot(i64 %4, i64 %sext10)
  %we_lp = inttoptr i64 %calltmp to ptr
  %we_lv = load i64, ptr %we_lp, align 8
  ret i64 %we_lv
}

define i64 @RawBuffer_i32_pop(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp eq i64 %sext, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %subtmp = sub i64 %sext4, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %3 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %3, 12
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %int_sext to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %4 = load i64, ptr %self, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %5, 12
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load i32, ptr %field_ptr8, align 4
  %sext10 = sext i32 %field_val9 to i64
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %4, i64 %sext10)
  %we_lp = inttoptr i64 %calltmp to ptr
  %we_lv = load i64, ptr %we_lp, align 8
  %valopt_box = call i64 @nova_valopt_box(i64 %we_lv)
  ret i64 %valopt_box
}

define i64 @RawBuffer_string_pop(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp eq i64 %sext, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %subtmp = sub i64 %sext4, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %3 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %3, 12
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %int_sext to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %4 = load i64, ptr %self, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %5, 12
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load i32, ptr %field_ptr8, align 4
  %sext10 = sext i32 %field_val9 to i64
  %calltmp = call i64 @RawBuffer_string_slot(i64 %4, i64 %sext10)
  %we_lp = inttoptr i64 %calltmp to ptr
  %we_lv = load i64, ptr %we_lp, align 8
  store i64 %we_lv, ptr %tmp_slot, align 8
  ret i64 %we_lv
}

define internal void @RawBuffer_insertAt(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %nc = alloca i64, align 8
  store i64 0, ptr %nc, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %3 = load i64, ptr %i, align 8
  %cmptmp = icmp slt i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %4 = load i64, ptr %i, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp1 = icmp sgt i64 %4, %sext
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %6, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i32, ptr %field_ptr4, align 4
  %sext6 = sext i32 %field_val5 to i64
  %7 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %7, 8
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load i32, ptr %field_ptr8, align 4
  %sext10 = sext i32 %field_val9 to i64
  %cmptmp11 = icmp sge i64 %sext6, %sext10
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %ifcond13 = icmp ne i64 %zexttmp12, 0
  br i1 %ifcond13, label %then14, label %ifcont15

then14:                                           ; preds = %ifcont
  %8 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %8, 8
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load i32, ptr %field_ptr17, align 4
  %sext19 = sext i32 %field_val18 to i64
  %cmptmp20 = icmp slt i64 %sext19, 1
  %zexttmp21 = zext i1 %cmptmp20 to i64
  %ifcond22 = icmp ne i64 %zexttmp21, 0
  br i1 %ifcond22, label %then23, label %else

ifcont15:                                         ; preds = %ifcont24, %ifcont
  %9 = load i64, ptr %self, align 8
  %field_addr29 = add i64 %9, 12
  %field_ptr30 = inttoptr i64 %field_addr29 to ptr
  %field_val31 = load i32, ptr %field_ptr30, align 4
  %sext32 = sext i32 %field_val31 to i64
  store i64 %sext32, ptr %j, align 8
  br label %while_cond

then23:                                           ; preds = %then14
  br label %ifcont24

else:                                             ; preds = %then14
  %10 = load i64, ptr %self, align 8
  %field_addr25 = add i64 %10, 8
  %field_ptr26 = inttoptr i64 %field_addr25 to ptr
  %field_val27 = load i32, ptr %field_ptr26, align 4
  %sext28 = sext i32 %field_val27 to i64
  %multmp = mul i64 %sext28, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  br label %ifcont24

ifcont24:                                         ; preds = %else, %then23
  %ifphi = phi i64 [ 1, %then23 ], [ %int_sext, %else ]
  store i64 %ifphi, ptr %nc, align 8
  %11 = load i64, ptr %self, align 8
  %12 = load i64, ptr %nc, align 8
  call void @RawBuffer_reserveExact(i64 %11, i64 %12)
  br label %ifcont15

while_cond:                                       ; preds = %while_body, %ifcont15
  %13 = load i64, ptr %j, align 8
  %14 = load i64, ptr %i, align 8
  %cmptmp33 = icmp sgt i64 %13, %14
  %zexttmp34 = zext i1 %cmptmp33 to i64
  %whilecond = icmp ne i64 %zexttmp34, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %15 = load i64, ptr %self, align 8
  %16 = load i64, ptr %j, align 8
  %calltmp = call i64 @RawBuffer_slot(i64 %15, i64 %16)
  %17 = load i64, ptr %self, align 8
  %18 = load i64, ptr %j, align 8
  %subtmp = sub i64 %18, 1
  %int_trunc35 = trunc i64 %subtmp to i32
  %int_sext36 = sext i32 %int_trunc35 to i64
  %calltmp37 = call i64 @RawBuffer_slot(i64 %17, i64 %int_sext36)
  %we_msp = inttoptr i64 %calltmp37 to ptr
  %we_mv = load i64, ptr %we_msp, align 8
  %we_mdp = inttoptr i64 %calltmp to ptr
  store i64 %we_mv, ptr %we_mdp, align 8
  %19 = load i64, ptr %j, align 8
  %subtmp38 = sub i64 %19, 1
  %int_trunc39 = trunc i64 %subtmp38 to i32
  %int_sext40 = sext i32 %int_trunc39 to i64
  store i64 %int_sext40, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %20 = load i64, ptr %self, align 8
  %21 = load i64, ptr %i, align 8
  %calltmp41 = call i64 @RawBuffer_slot(i64 %20, i64 %21)
  %22 = load i64, ptr %value, align 8
  %we_sp = inttoptr i64 %calltmp41 to ptr
  store i64 %22, ptr %we_sp, align 8
  %23 = load i64, ptr %self, align 8
  %field_addr42 = add i64 %23, 12
  %field_ptr43 = inttoptr i64 %field_addr42 to ptr
  %field_val44 = load i32, ptr %field_ptr43, align 4
  %sext45 = sext i32 %field_val44 to i64
  %addtmp = add i64 %sext45, 1
  %int_trunc46 = trunc i64 %addtmp to i32
  %int_sext47 = sext i32 %int_trunc46 to i64
  %24 = load i64, ptr %self, align 8
  %field_addr48 = add i64 %24, 12
  %field_ptr49 = inttoptr i64 %field_addr48 to ptr
  %trunc = trunc i64 %int_sext47 to i32
  store i32 %trunc, ptr %field_ptr49, align 4
  ret void
}

define void @RawBuffer_i32_insertAt(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %nc = alloca i64, align 8
  store i64 0, ptr %nc, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %3 = load i64, ptr %i, align 8
  %cmptmp = icmp slt i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %4 = load i64, ptr %i, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp1 = icmp sgt i64 %4, %sext
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %6, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i32, ptr %field_ptr4, align 4
  %sext6 = sext i32 %field_val5 to i64
  %7 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %7, 8
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load i32, ptr %field_ptr8, align 4
  %sext10 = sext i32 %field_val9 to i64
  %cmptmp11 = icmp sge i64 %sext6, %sext10
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %ifcond13 = icmp ne i64 %zexttmp12, 0
  br i1 %ifcond13, label %then14, label %ifcont15

then14:                                           ; preds = %ifcont
  %8 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %8, 8
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load i32, ptr %field_ptr17, align 4
  %sext19 = sext i32 %field_val18 to i64
  %cmptmp20 = icmp slt i64 %sext19, 1
  %zexttmp21 = zext i1 %cmptmp20 to i64
  %ifcond22 = icmp ne i64 %zexttmp21, 0
  br i1 %ifcond22, label %then23, label %else

ifcont15:                                         ; preds = %ifcont24, %ifcont
  %9 = load i64, ptr %self, align 8
  %field_addr29 = add i64 %9, 12
  %field_ptr30 = inttoptr i64 %field_addr29 to ptr
  %field_val31 = load i32, ptr %field_ptr30, align 4
  %sext32 = sext i32 %field_val31 to i64
  store i64 %sext32, ptr %j, align 8
  br label %while_cond

then23:                                           ; preds = %then14
  br label %ifcont24

else:                                             ; preds = %then14
  %10 = load i64, ptr %self, align 8
  %field_addr25 = add i64 %10, 8
  %field_ptr26 = inttoptr i64 %field_addr25 to ptr
  %field_val27 = load i32, ptr %field_ptr26, align 4
  %sext28 = sext i32 %field_val27 to i64
  %multmp = mul i64 %sext28, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  br label %ifcont24

ifcont24:                                         ; preds = %else, %then23
  %ifphi = phi i64 [ 1, %then23 ], [ %int_sext, %else ]
  store i64 %ifphi, ptr %nc, align 8
  %11 = load i64, ptr %self, align 8
  %12 = load i64, ptr %nc, align 8
  call void @RawBuffer_i32_reserveExact(i64 %11, i64 %12)
  br label %ifcont15

while_cond:                                       ; preds = %while_body, %ifcont15
  %13 = load i64, ptr %j, align 8
  %14 = load i64, ptr %i, align 8
  %cmptmp33 = icmp sgt i64 %13, %14
  %zexttmp34 = zext i1 %cmptmp33 to i64
  %whilecond = icmp ne i64 %zexttmp34, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %15 = load i64, ptr %self, align 8
  %16 = load i64, ptr %j, align 8
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %15, i64 %16)
  %17 = load i64, ptr %self, align 8
  %18 = load i64, ptr %j, align 8
  %subtmp = sub i64 %18, 1
  %int_trunc35 = trunc i64 %subtmp to i32
  %int_sext36 = sext i32 %int_trunc35 to i64
  %calltmp37 = call i64 @RawBuffer_i32_slot(i64 %17, i64 %int_sext36)
  %we_msp = inttoptr i64 %calltmp37 to ptr
  %we_mv = load i64, ptr %we_msp, align 8
  %we_mdp = inttoptr i64 %calltmp to ptr
  store i64 %we_mv, ptr %we_mdp, align 8
  %19 = load i64, ptr %j, align 8
  %subtmp38 = sub i64 %19, 1
  %int_trunc39 = trunc i64 %subtmp38 to i32
  %int_sext40 = sext i32 %int_trunc39 to i64
  store i64 %int_sext40, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %20 = load i64, ptr %self, align 8
  %21 = load i64, ptr %i, align 8
  %calltmp41 = call i64 @RawBuffer_i32_slot(i64 %20, i64 %21)
  %22 = load i64, ptr %value, align 8
  %we_sp = inttoptr i64 %calltmp41 to ptr
  store i64 %22, ptr %we_sp, align 8
  %23 = load i64, ptr %self, align 8
  %field_addr42 = add i64 %23, 12
  %field_ptr43 = inttoptr i64 %field_addr42 to ptr
  %field_val44 = load i32, ptr %field_ptr43, align 4
  %sext45 = sext i32 %field_val44 to i64
  %addtmp = add i64 %sext45, 1
  %int_trunc46 = trunc i64 %addtmp to i32
  %int_sext47 = sext i32 %int_trunc46 to i64
  %24 = load i64, ptr %self, align 8
  %field_addr48 = add i64 %24, 12
  %field_ptr49 = inttoptr i64 %field_addr48 to ptr
  %trunc = trunc i64 %int_sext47 to i32
  store i32 %trunc, ptr %field_ptr49, align 4
  ret void
}

define void @RawBuffer_string_insertAt(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %nc = alloca i64, align 8
  store i64 0, ptr %nc, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %3 = load i64, ptr %i, align 8
  %cmptmp = icmp slt i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %4 = load i64, ptr %i, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp1 = icmp sgt i64 %4, %sext
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %6, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i32, ptr %field_ptr4, align 4
  %sext6 = sext i32 %field_val5 to i64
  %7 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %7, 8
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load i32, ptr %field_ptr8, align 4
  %sext10 = sext i32 %field_val9 to i64
  %cmptmp11 = icmp sge i64 %sext6, %sext10
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %ifcond13 = icmp ne i64 %zexttmp12, 0
  br i1 %ifcond13, label %then14, label %ifcont15

then14:                                           ; preds = %ifcont
  %8 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %8, 8
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load i32, ptr %field_ptr17, align 4
  %sext19 = sext i32 %field_val18 to i64
  %cmptmp20 = icmp slt i64 %sext19, 1
  %zexttmp21 = zext i1 %cmptmp20 to i64
  %ifcond22 = icmp ne i64 %zexttmp21, 0
  br i1 %ifcond22, label %then23, label %else

ifcont15:                                         ; preds = %ifcont24, %ifcont
  %9 = load i64, ptr %self, align 8
  %field_addr29 = add i64 %9, 12
  %field_ptr30 = inttoptr i64 %field_addr29 to ptr
  %field_val31 = load i32, ptr %field_ptr30, align 4
  %sext32 = sext i32 %field_val31 to i64
  store i64 %sext32, ptr %j, align 8
  br label %while_cond

then23:                                           ; preds = %then14
  br label %ifcont24

else:                                             ; preds = %then14
  %10 = load i64, ptr %self, align 8
  %field_addr25 = add i64 %10, 8
  %field_ptr26 = inttoptr i64 %field_addr25 to ptr
  %field_val27 = load i32, ptr %field_ptr26, align 4
  %sext28 = sext i32 %field_val27 to i64
  %multmp = mul i64 %sext28, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  br label %ifcont24

ifcont24:                                         ; preds = %else, %then23
  %ifphi = phi i64 [ 1, %then23 ], [ %int_sext, %else ]
  store i64 %ifphi, ptr %nc, align 8
  %11 = load i64, ptr %self, align 8
  %12 = load i64, ptr %nc, align 8
  call void @RawBuffer_string_reserveExact(i64 %11, i64 %12)
  br label %ifcont15

while_cond:                                       ; preds = %while_body, %ifcont15
  %13 = load i64, ptr %j, align 8
  %14 = load i64, ptr %i, align 8
  %cmptmp33 = icmp sgt i64 %13, %14
  %zexttmp34 = zext i1 %cmptmp33 to i64
  %whilecond = icmp ne i64 %zexttmp34, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %15 = load i64, ptr %self, align 8
  %16 = load i64, ptr %j, align 8
  %calltmp = call i64 @RawBuffer_string_slot(i64 %15, i64 %16)
  %17 = load i64, ptr %self, align 8
  %18 = load i64, ptr %j, align 8
  %subtmp = sub i64 %18, 1
  %int_trunc35 = trunc i64 %subtmp to i32
  %int_sext36 = sext i32 %int_trunc35 to i64
  %calltmp37 = call i64 @RawBuffer_string_slot(i64 %17, i64 %int_sext36)
  %we_msp = inttoptr i64 %calltmp37 to ptr
  %we_mv = load i64, ptr %we_msp, align 8
  %we_mdp = inttoptr i64 %calltmp to ptr
  store i64 %we_mv, ptr %we_mdp, align 8
  %19 = load i64, ptr %j, align 8
  %subtmp38 = sub i64 %19, 1
  %int_trunc39 = trunc i64 %subtmp38 to i32
  %int_sext40 = sext i32 %int_trunc39 to i64
  store i64 %int_sext40, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %20 = load i64, ptr %self, align 8
  %21 = load i64, ptr %i, align 8
  %calltmp41 = call i64 @RawBuffer_string_slot(i64 %20, i64 %21)
  %22 = load i64, ptr %value, align 8
  call void @nova_retain(i64 %22)
  %we_sp = inttoptr i64 %calltmp41 to ptr
  store i64 %22, ptr %we_sp, align 8
  %23 = load i64, ptr %self, align 8
  %field_addr42 = add i64 %23, 12
  %field_ptr43 = inttoptr i64 %field_addr42 to ptr
  %field_val44 = load i32, ptr %field_ptr43, align 4
  %sext45 = sext i32 %field_val44 to i64
  %addtmp = add i64 %sext45, 1
  %int_trunc46 = trunc i64 %addtmp to i32
  %int_sext47 = sext i32 %int_trunc46 to i64
  %24 = load i64, ptr %self, align 8
  %field_addr48 = add i64 %24, 12
  %field_ptr49 = inttoptr i64 %field_addr48 to ptr
  %trunc = trunc i64 %int_sext47 to i32
  store i32 %trunc, ptr %field_ptr49, align 4
  ret void
}

define internal void @RawBuffer_removeAt(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %2 = load i64, ptr %i, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp1 = icmp sge i64 %3, %sext
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %5 = load i64, ptr %self, align 8
  %6 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_slot(i64 %5, i64 %6)
  %7 = load i64, ptr %i, align 8
  store i64 %7, ptr %j, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %ifcont
  %8 = load i64, ptr %j, align 8
  %9 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %9, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i32, ptr %field_ptr4, align 4
  %sext6 = sext i32 %field_val5 to i64
  %subtmp = sub i64 %sext6, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cmptmp7 = icmp slt i64 %8, %int_sext
  %zexttmp8 = zext i1 %cmptmp7 to i64
  %whilecond = icmp ne i64 %zexttmp8, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %10 = load i64, ptr %self, align 8
  %11 = load i64, ptr %j, align 8
  %calltmp9 = call i64 @RawBuffer_slot(i64 %10, i64 %11)
  %12 = load i64, ptr %self, align 8
  %13 = load i64, ptr %j, align 8
  %addtmp = add i64 %13, 1
  %int_trunc10 = trunc i64 %addtmp to i32
  %int_sext11 = sext i32 %int_trunc10 to i64
  %calltmp12 = call i64 @RawBuffer_slot(i64 %12, i64 %int_sext11)
  %we_msp = inttoptr i64 %calltmp12 to ptr
  %we_mv = load i64, ptr %we_msp, align 8
  %we_mdp = inttoptr i64 %calltmp9 to ptr
  store i64 %we_mv, ptr %we_mdp, align 8
  %14 = load i64, ptr %j, align 8
  %addtmp13 = add i64 %14, 1
  %int_trunc14 = trunc i64 %addtmp13 to i32
  %int_sext15 = sext i32 %int_trunc14 to i64
  store i64 %int_sext15, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %15 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %15, 12
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load i32, ptr %field_ptr17, align 4
  %sext19 = sext i32 %field_val18 to i64
  %subtmp20 = sub i64 %sext19, 1
  %int_trunc21 = trunc i64 %subtmp20 to i32
  %int_sext22 = sext i32 %int_trunc21 to i64
  %16 = load i64, ptr %self, align 8
  %field_addr23 = add i64 %16, 12
  %field_ptr24 = inttoptr i64 %field_addr23 to ptr
  %trunc = trunc i64 %int_sext22 to i32
  store i32 %trunc, ptr %field_ptr24, align 4
  ret void
}

define void @RawBuffer_i32_removeAt(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %2 = load i64, ptr %i, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp1 = icmp sge i64 %3, %sext
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %5 = load i64, ptr %self, align 8
  %6 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %5, i64 %6)
  %7 = load i64, ptr %i, align 8
  store i64 %7, ptr %j, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %ifcont
  %8 = load i64, ptr %j, align 8
  %9 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %9, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i32, ptr %field_ptr4, align 4
  %sext6 = sext i32 %field_val5 to i64
  %subtmp = sub i64 %sext6, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cmptmp7 = icmp slt i64 %8, %int_sext
  %zexttmp8 = zext i1 %cmptmp7 to i64
  %whilecond = icmp ne i64 %zexttmp8, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %10 = load i64, ptr %self, align 8
  %11 = load i64, ptr %j, align 8
  %calltmp9 = call i64 @RawBuffer_i32_slot(i64 %10, i64 %11)
  %12 = load i64, ptr %self, align 8
  %13 = load i64, ptr %j, align 8
  %addtmp = add i64 %13, 1
  %int_trunc10 = trunc i64 %addtmp to i32
  %int_sext11 = sext i32 %int_trunc10 to i64
  %calltmp12 = call i64 @RawBuffer_i32_slot(i64 %12, i64 %int_sext11)
  %we_msp = inttoptr i64 %calltmp12 to ptr
  %we_mv = load i64, ptr %we_msp, align 8
  %we_mdp = inttoptr i64 %calltmp9 to ptr
  store i64 %we_mv, ptr %we_mdp, align 8
  %14 = load i64, ptr %j, align 8
  %addtmp13 = add i64 %14, 1
  %int_trunc14 = trunc i64 %addtmp13 to i32
  %int_sext15 = sext i32 %int_trunc14 to i64
  store i64 %int_sext15, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %15 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %15, 12
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load i32, ptr %field_ptr17, align 4
  %sext19 = sext i32 %field_val18 to i64
  %subtmp20 = sub i64 %sext19, 1
  %int_trunc21 = trunc i64 %subtmp20 to i32
  %int_sext22 = sext i32 %int_trunc21 to i64
  %16 = load i64, ptr %self, align 8
  %field_addr23 = add i64 %16, 12
  %field_ptr24 = inttoptr i64 %field_addr23 to ptr
  %trunc = trunc i64 %int_sext22 to i32
  store i32 %trunc, ptr %field_ptr24, align 4
  ret void
}

define void @RawBuffer_string_removeAt(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 %1, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %2 = load i64, ptr %i, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp1 = icmp sge i64 %3, %sext
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %5 = load i64, ptr %self, align 8
  %6 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_string_slot(i64 %5, i64 %6)
  %we_dp = inttoptr i64 %calltmp to ptr
  %we_dv = load i64, ptr %we_dp, align 8
  call void @nova_release(i64 %we_dv, ptr null)
  %7 = load i64, ptr %i, align 8
  store i64 %7, ptr %j, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %ifcont
  %8 = load i64, ptr %j, align 8
  %9 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %9, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i32, ptr %field_ptr4, align 4
  %sext6 = sext i32 %field_val5 to i64
  %subtmp = sub i64 %sext6, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cmptmp7 = icmp slt i64 %8, %int_sext
  %zexttmp8 = zext i1 %cmptmp7 to i64
  %whilecond = icmp ne i64 %zexttmp8, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %10 = load i64, ptr %self, align 8
  %11 = load i64, ptr %j, align 8
  %calltmp9 = call i64 @RawBuffer_string_slot(i64 %10, i64 %11)
  %12 = load i64, ptr %self, align 8
  %13 = load i64, ptr %j, align 8
  %addtmp = add i64 %13, 1
  %int_trunc10 = trunc i64 %addtmp to i32
  %int_sext11 = sext i32 %int_trunc10 to i64
  %calltmp12 = call i64 @RawBuffer_string_slot(i64 %12, i64 %int_sext11)
  %we_msp = inttoptr i64 %calltmp12 to ptr
  %we_mv = load i64, ptr %we_msp, align 8
  %we_mdp = inttoptr i64 %calltmp9 to ptr
  store i64 %we_mv, ptr %we_mdp, align 8
  %14 = load i64, ptr %j, align 8
  %addtmp13 = add i64 %14, 1
  %int_trunc14 = trunc i64 %addtmp13 to i32
  %int_sext15 = sext i32 %int_trunc14 to i64
  store i64 %int_sext15, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %15 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %15, 12
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load i32, ptr %field_ptr17, align 4
  %sext19 = sext i32 %field_val18 to i64
  %subtmp20 = sub i64 %sext19, 1
  %int_trunc21 = trunc i64 %subtmp20 to i32
  %int_sext22 = sext i32 %int_trunc21 to i64
  %16 = load i64, ptr %self, align 8
  %field_addr23 = add i64 %16, 12
  %field_ptr24 = inttoptr i64 %field_addr23 to ptr
  %trunc = trunc i64 %int_sext22 to i32
  store i32 %trunc, ptr %field_ptr24, align 4
  ret void
}

define internal void @RawBuffer_clear(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %1 = load i64, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp slt i64 %1, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %i, align 8
  %addtmp = add i64 %5, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  ret void
}

define void @RawBuffer_i32_clear(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %1 = load i64, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp slt i64 %1, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %i, align 8
  %addtmp = add i64 %5, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  ret void
}

define void @RawBuffer_string_clear(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %1 = load i64, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp slt i64 %1, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_string_slot(i64 %3, i64 %4)
  %we_dp = inttoptr i64 %calltmp to ptr
  %we_dv = load i64, ptr %we_dp, align 8
  call void @nova_release(i64 %we_dv, ptr null)
  %5 = load i64, ptr %i, align 8
  %addtmp = add i64 %5, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  ret void
}

define internal void @RawBuffer_reserveExact(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %nc = alloca i64, align 8
  store i64 %1, ptr %nc, align 8
  %w = alloca i64, align 8
  store i64 0, ptr %w, align 8
  %nd = alloca i64, align 8
  store i64 0, ptr %nd, align 8
  %2 = load i64, ptr %nc, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp sle i64 %2, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  store i64 8, ptr %w, align 8
  %4 = load i64, ptr %nc, align 8
  %multmp = mul i64 %4, 8
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext)
  store i64 %alloc_tmp, ptr %nd, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %cmptmp5 = icmp sgt i64 %sext4, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  %6 = load i64, ptr %nd, align 8
  %7 = load i64, ptr %self, align 8
  %field_addr10 = add i64 %7, 0
  %field_ptr11 = inttoptr i64 %field_addr10 to ptr
  %field_val12 = load i64, ptr %field_ptr11, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr13 = add i64 %8, 12
  %field_ptr14 = inttoptr i64 %field_addr13 to ptr
  %field_val15 = load i32, ptr %field_ptr14, align 4
  %sext16 = sext i32 %field_val15 to i64
  %9 = load i64, ptr %w, align 8
  %multmp17 = mul i64 %sext16, %9
  call void @nova_bytes_copy(i64 %6, i64 %field_val12, i64 %multmp17)
  br label %ifcont9

ifcont9:                                          ; preds = %then8, %ifcont
  %10 = load i64, ptr %self, align 8
  %field_addr18 = add i64 %10, 0
  %field_ptr19 = inttoptr i64 %field_addr18 to ptr
  %field_val20 = load i64, ptr %field_ptr19, align 8
  call void @nova_bytes_free(i64 %field_val20)
  %11 = load i64, ptr %nd, align 8
  %12 = load i64, ptr %self, align 8
  %field_addr21 = add i64 %12, 0
  %field_ptr22 = inttoptr i64 %field_addr21 to ptr
  store i64 %11, ptr %field_ptr22, align 8
  %13 = load i64, ptr %nc, align 8
  %14 = load i64, ptr %self, align 8
  %field_addr23 = add i64 %14, 8
  %field_ptr24 = inttoptr i64 %field_addr23 to ptr
  %trunc = trunc i64 %13 to i32
  store i32 %trunc, ptr %field_ptr24, align 4
  ret void
}

define void @RawBuffer_i32_reserveExact(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %nc = alloca i64, align 8
  store i64 %1, ptr %nc, align 8
  %w = alloca i64, align 8
  store i64 0, ptr %w, align 8
  %nd = alloca i64, align 8
  store i64 0, ptr %nd, align 8
  %2 = load i64, ptr %nc, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp sle i64 %2, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  store i64 8, ptr %w, align 8
  %4 = load i64, ptr %nc, align 8
  %multmp = mul i64 %4, 8
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext)
  store i64 %alloc_tmp, ptr %nd, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %cmptmp5 = icmp sgt i64 %sext4, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  %6 = load i64, ptr %nd, align 8
  %7 = load i64, ptr %self, align 8
  %field_addr10 = add i64 %7, 0
  %field_ptr11 = inttoptr i64 %field_addr10 to ptr
  %field_val12 = load i64, ptr %field_ptr11, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr13 = add i64 %8, 12
  %field_ptr14 = inttoptr i64 %field_addr13 to ptr
  %field_val15 = load i32, ptr %field_ptr14, align 4
  %sext16 = sext i32 %field_val15 to i64
  %9 = load i64, ptr %w, align 8
  %multmp17 = mul i64 %sext16, %9
  call void @nova_bytes_copy(i64 %6, i64 %field_val12, i64 %multmp17)
  br label %ifcont9

ifcont9:                                          ; preds = %then8, %ifcont
  %10 = load i64, ptr %self, align 8
  %field_addr18 = add i64 %10, 0
  %field_ptr19 = inttoptr i64 %field_addr18 to ptr
  %field_val20 = load i64, ptr %field_ptr19, align 8
  call void @nova_bytes_free(i64 %field_val20)
  %11 = load i64, ptr %nd, align 8
  %12 = load i64, ptr %self, align 8
  %field_addr21 = add i64 %12, 0
  %field_ptr22 = inttoptr i64 %field_addr21 to ptr
  store i64 %11, ptr %field_ptr22, align 8
  %13 = load i64, ptr %nc, align 8
  %14 = load i64, ptr %self, align 8
  %field_addr23 = add i64 %14, 8
  %field_ptr24 = inttoptr i64 %field_addr23 to ptr
  %trunc = trunc i64 %13 to i32
  store i32 %trunc, ptr %field_ptr24, align 4
  ret void
}

define void @RawBuffer_string_reserveExact(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %nc = alloca i64, align 8
  store i64 %1, ptr %nc, align 8
  %w = alloca i64, align 8
  store i64 0, ptr %w, align 8
  %nd = alloca i64, align 8
  store i64 0, ptr %nd, align 8
  %2 = load i64, ptr %nc, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp sle i64 %2, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  store i64 8, ptr %w, align 8
  %4 = load i64, ptr %nc, align 8
  %multmp = mul i64 %4, 8
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext)
  store i64 %alloc_tmp, ptr %nd, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %cmptmp5 = icmp sgt i64 %sext4, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  %6 = load i64, ptr %nd, align 8
  %7 = load i64, ptr %self, align 8
  %field_addr10 = add i64 %7, 0
  %field_ptr11 = inttoptr i64 %field_addr10 to ptr
  %field_val12 = load i64, ptr %field_ptr11, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr13 = add i64 %8, 12
  %field_ptr14 = inttoptr i64 %field_addr13 to ptr
  %field_val15 = load i32, ptr %field_ptr14, align 4
  %sext16 = sext i32 %field_val15 to i64
  %9 = load i64, ptr %w, align 8
  %multmp17 = mul i64 %sext16, %9
  call void @nova_bytes_copy(i64 %6, i64 %field_val12, i64 %multmp17)
  br label %ifcont9

ifcont9:                                          ; preds = %then8, %ifcont
  %10 = load i64, ptr %self, align 8
  %field_addr18 = add i64 %10, 0
  %field_ptr19 = inttoptr i64 %field_addr18 to ptr
  %field_val20 = load i64, ptr %field_ptr19, align 8
  call void @nova_bytes_free(i64 %field_val20)
  %11 = load i64, ptr %nd, align 8
  %12 = load i64, ptr %self, align 8
  %field_addr21 = add i64 %12, 0
  %field_ptr22 = inttoptr i64 %field_addr21 to ptr
  store i64 %11, ptr %field_ptr22, align 8
  %13 = load i64, ptr %nc, align 8
  %14 = load i64, ptr %self, align 8
  %field_addr23 = add i64 %14, 8
  %field_ptr24 = inttoptr i64 %field_addr23 to ptr
  %trunc = trunc i64 %13 to i32
  store i32 %trunc, ptr %field_ptr24, align 4
  ret void
}

define internal void @RawBuffer_delete(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %1 = load i64, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp slt i64 %1, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %i, align 8
  %addtmp = add i64 %5, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  %cmptmp4 = icmp ne i64 %field_val3, 0
  %zexttmp5 = zext i1 %cmptmp4 to i64
  %ifcond = icmp ne i64 %zexttmp5, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %while_exit
  %7 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %7, 0
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %field_val8 = load i64, ptr %field_ptr7, align 8
  call void @nova_bytes_free(i64 %field_val8)
  %8 = load i64, ptr %self, align 8
  %field_addr9 = add i64 %8, 0
  %field_ptr10 = inttoptr i64 %field_addr9 to ptr
  store i64 0, ptr %field_ptr10, align 8
  %9 = load i64, ptr %self, align 8
  %field_addr11 = add i64 %9, 12
  %field_ptr12 = inttoptr i64 %field_addr11 to ptr
  store i32 0, ptr %field_ptr12, align 4
  br label %ifcont

ifcont:                                           ; preds = %then, %while_exit
  ret void
}

define void @RawBuffer_i32_delete(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %1 = load i64, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp slt i64 %1, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_i32_slot(i64 %3, i64 %4)
  %5 = load i64, ptr %i, align 8
  %addtmp = add i64 %5, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  %cmptmp4 = icmp ne i64 %field_val3, 0
  %zexttmp5 = zext i1 %cmptmp4 to i64
  %ifcond = icmp ne i64 %zexttmp5, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %while_exit
  %7 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %7, 0
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %field_val8 = load i64, ptr %field_ptr7, align 8
  call void @nova_bytes_free(i64 %field_val8)
  %8 = load i64, ptr %self, align 8
  %field_addr9 = add i64 %8, 0
  %field_ptr10 = inttoptr i64 %field_addr9 to ptr
  store i64 0, ptr %field_ptr10, align 8
  %9 = load i64, ptr %self, align 8
  %field_addr11 = add i64 %9, 12
  %field_ptr12 = inttoptr i64 %field_addr11 to ptr
  store i32 0, ptr %field_ptr12, align 4
  br label %ifcont

ifcont:                                           ; preds = %then, %while_exit
  ret void
}

define void @RawBuffer_string_delete(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %1 = load i64, ptr %i, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp slt i64 %1, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %3 = load i64, ptr %self, align 8
  %4 = load i64, ptr %i, align 8
  %calltmp = call i64 @RawBuffer_string_slot(i64 %3, i64 %4)
  %we_dp = inttoptr i64 %calltmp to ptr
  %we_dv = load i64, ptr %we_dp, align 8
  call void @nova_release(i64 %we_dv, ptr null)
  %5 = load i64, ptr %i, align 8
  %addtmp = add i64 %5, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  %cmptmp4 = icmp ne i64 %field_val3, 0
  %zexttmp5 = zext i1 %cmptmp4 to i64
  %ifcond = icmp ne i64 %zexttmp5, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %while_exit
  %7 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %7, 0
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %field_val8 = load i64, ptr %field_ptr7, align 8
  call void @nova_bytes_free(i64 %field_val8)
  %8 = load i64, ptr %self, align 8
  %field_addr9 = add i64 %8, 0
  %field_ptr10 = inttoptr i64 %field_addr9 to ptr
  store i64 0, ptr %field_ptr10, align 8
  %9 = load i64, ptr %self, align 8
  %field_addr11 = add i64 %9, 12
  %field_ptr12 = inttoptr i64 %field_addr11 to ptr
  store i32 0, ptr %field_ptr12, align 4
  br label %ifcont

ifcont:                                           ; preds = %then, %while_exit
  ret void
}

declare void @List_init(i64)

define void @List_i32_init(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @RawBuffer_i32_init(i64 %alloc_tmp, i64 4)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %old_field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %old_field_val to i64
  call void @nova_release(i64 %ptr_to_int, ptr @__destruct_RawBuffer_i32)
  %int_to_ptr = inttoptr i64 %alloc_tmp to ptr
  store ptr %int_to_ptr, ptr %field_ptr, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  %3 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %3, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  store i32 4, ptr %field_ptr4, align 4
  ret void
}

define void @List_string_init(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @RawBuffer_string_init(i64 %alloc_tmp, i64 4)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %old_field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %old_field_val to i64
  call void @nova_release(i64 %ptr_to_int, ptr @__destruct_RawBuffer_string)
  %int_to_ptr = inttoptr i64 %alloc_tmp to ptr
  store ptr %int_to_ptr, ptr %field_ptr, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  %3 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %3, 12
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  store i32 4, ptr %field_ptr4, align 4
  ret void
}

declare void @List_push(i64, i64)

define void @List_i32_push(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %3 = load i64, ptr %value, align 8
  call void @RawBuffer_i32_push(i64 %ptr_to_int, i64 %3)
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int4)
  %5 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %5, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %calltmp to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %6 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %6, 0
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load ptr, ptr %field_ptr8, align 8
  %ptr_to_int10 = ptrtoint ptr %field_val9 to i64
  %calltmp11 = call i64 @RawBuffer_i32_capacity(i64 %ptr_to_int10)
  %7 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %7, 12
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %trunc14 = trunc i64 %calltmp11 to i32
  store i32 %trunc14, ptr %field_ptr13, align 4
  ret void
}

define void @List_string_push(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %3 = load i64, ptr %value, align 8
  call void @RawBuffer_string_push(i64 %ptr_to_int, i64 %3)
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int4)
  %5 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %5, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %calltmp to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %6 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %6, 0
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load ptr, ptr %field_ptr8, align 8
  %ptr_to_int10 = ptrtoint ptr %field_val9 to i64
  %calltmp11 = call i64 @RawBuffer_string_capacity(i64 %ptr_to_int10)
  %7 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %7, 12
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %trunc14 = trunc i64 %calltmp11 to i32
  store i32 %trunc14, ptr %field_ptr13, align 4
  ret void
}

declare i64 @List_get(i64, i64)

define i64 @List_i32_get(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %2 = load i64, ptr %index, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %index, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp1 = icmp sge i64 %3, %calltmp
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %5 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %5, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load ptr, ptr %field_ptr4, align 8
  %ptr_to_int6 = ptrtoint ptr %field_val5 to i64
  %6 = load i64, ptr %index, align 8
  %calltmp7 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int6, i64 %6)
  %valopt_box = call i64 @nova_valopt_box(i64 %calltmp7)
  ret i64 %valopt_box
}

define i64 @List_string_get(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %2 = load i64, ptr %index, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %index, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp1 = icmp sge i64 %3, %calltmp
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %5 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %5, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load ptr, ptr %field_ptr4, align 8
  %ptr_to_int6 = ptrtoint ptr %field_val5 to i64
  %6 = load i64, ptr %index, align 8
  %calltmp7 = call i64 @RawBuffer_string_at(i64 %ptr_to_int6, i64 %6)
  store i64 %calltmp7, ptr %tmp_slot, align 8
  ret i64 %calltmp7
}

declare i64 @List_at(i64, i64)

define i64 @List_i32_at(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %2 = load i64, ptr %index, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %index, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp1 = icmp sge i64 %3, %calltmp
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_panic(ptr getelementptr inbounds nuw (<{ i32, i32, [28 x i8] }>, ptr @str_literal, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  %5 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %5, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load ptr, ptr %field_ptr4, align 8
  %ptr_to_int6 = ptrtoint ptr %field_val5 to i64
  %6 = load i64, ptr %index, align 8
  %calltmp7 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int6, i64 %6)
  ret i64 %calltmp7
}

define i64 @List_string_at(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %2 = load i64, ptr %index, align 8
  %cmptmp = icmp slt i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %index, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr = add i64 %4, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp1 = icmp sge i64 %3, %calltmp
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_panic(ptr getelementptr inbounds nuw (<{ i32, i32, [28 x i8] }>, ptr @str_literal, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  %5 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %5, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load ptr, ptr %field_ptr4, align 8
  %ptr_to_int6 = ptrtoint ptr %field_val5 to i64
  %6 = load i64, ptr %index, align 8
  %calltmp7 = call i64 @RawBuffer_string_at(i64 %ptr_to_int6, i64 %6)
  store i64 %calltmp7, ptr %tmp_slot, align 8
  ret i64 %calltmp7
}

declare void @List_set(i64, i64, i64)

define void @List_i32_set(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %index, align 8
  %cmptmp = icmp slt i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %4 = load i64, ptr %index, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp1 = icmp sge i64 %4, %calltmp
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %6, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load ptr, ptr %field_ptr4, align 8
  %ptr_to_int6 = ptrtoint ptr %field_val5 to i64
  %7 = load i64, ptr %index, align 8
  %8 = load i64, ptr %value, align 8
  call void @RawBuffer_i32_set(i64 %ptr_to_int6, i64 %7, i64 %8)
  ret void
}

define void @List_string_set(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %index, align 8
  %cmptmp = icmp slt i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %4 = load i64, ptr %index, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp1 = icmp sge i64 %4, %calltmp
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %6, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load ptr, ptr %field_ptr4, align 8
  %ptr_to_int6 = ptrtoint ptr %field_val5 to i64
  %7 = load i64, ptr %index, align 8
  %8 = load i64, ptr %value, align 8
  call void @RawBuffer_string_set(i64 %ptr_to_int6, i64 %7, i64 %8)
  ret void
}

declare void @List_insert(i64, i64, i64)

define void @List_i32_insert(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %4 = load i64, ptr %index, align 8
  %5 = load i64, ptr %value, align 8
  call void @RawBuffer_i32_insertAt(i64 %ptr_to_int, i64 %4, i64 %5)
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int4)
  %7 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %7, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %calltmp to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %8 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %8, 0
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load ptr, ptr %field_ptr8, align 8
  %ptr_to_int10 = ptrtoint ptr %field_val9 to i64
  %calltmp11 = call i64 @RawBuffer_i32_capacity(i64 %ptr_to_int10)
  %9 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %9, 12
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %trunc14 = trunc i64 %calltmp11 to i32
  store i32 %trunc14, ptr %field_ptr13, align 4
  ret void
}

define void @List_string_insert(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %value = alloca i64, align 8
  store i64 %2, ptr %value, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %4 = load i64, ptr %index, align 8
  %5 = load i64, ptr %value, align 8
  call void @RawBuffer_string_insertAt(i64 %ptr_to_int, i64 %4, i64 %5)
  %6 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %6, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int4)
  %7 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %7, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %calltmp to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %8 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %8, 0
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load ptr, ptr %field_ptr8, align 8
  %ptr_to_int10 = ptrtoint ptr %field_val9 to i64
  %calltmp11 = call i64 @RawBuffer_string_capacity(i64 %ptr_to_int10)
  %9 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %9, 12
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %trunc14 = trunc i64 %calltmp11 to i32
  store i32 %trunc14, ptr %field_ptr13, align 4
  ret void
}

declare void @List_remove(i64, i64)

define void @List_i32_remove(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %3 = load i64, ptr %index, align 8
  call void @RawBuffer_i32_removeAt(i64 %ptr_to_int, i64 %3)
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int4)
  %5 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %5, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %calltmp to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %6 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %6, 0
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load ptr, ptr %field_ptr8, align 8
  %ptr_to_int10 = ptrtoint ptr %field_val9 to i64
  %calltmp11 = call i64 @RawBuffer_i32_capacity(i64 %ptr_to_int10)
  %7 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %7, 12
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %trunc14 = trunc i64 %calltmp11 to i32
  store i32 %trunc14, ptr %field_ptr13, align 4
  ret void
}

define void @List_string_remove(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %index = alloca i64, align 8
  store i64 %1, ptr %index, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %3 = load i64, ptr %index, align 8
  call void @RawBuffer_string_removeAt(i64 %ptr_to_int, i64 %3)
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int4)
  %5 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %5, 8
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %trunc = trunc i64 %calltmp to i32
  store i32 %trunc, ptr %field_ptr6, align 4
  %6 = load i64, ptr %self, align 8
  %field_addr7 = add i64 %6, 0
  %field_ptr8 = inttoptr i64 %field_addr7 to ptr
  %field_val9 = load ptr, ptr %field_ptr8, align 8
  %ptr_to_int10 = ptrtoint ptr %field_val9 to i64
  %calltmp11 = call i64 @RawBuffer_string_capacity(i64 %ptr_to_int10)
  %7 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %7, 12
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %trunc14 = trunc i64 %calltmp11 to i32
  store i32 %trunc14, ptr %field_ptr13, align 4
  ret void
}

declare i64 @List_size(i64)

define i64 @List_i32_size(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  ret i64 %calltmp
}

define i64 @List_string_size(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  ret i64 %calltmp
}

declare void @List_forEach(i64, i64)

define void @List_i32_forEach(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %fn = alloca i64, align 8
  store i64 %1, ptr %fn, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %val = alloca i64, align 8
  store i64 0, ptr %val, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %val, align 8
  %6 = load i64, ptr %fn, align 8
  %clo_box = inttoptr i64 %6 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %6, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %7 = load i64, ptr %val, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %7)
  %8 = load i64, ptr %i, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  ret void
}

define void @List_string_forEach(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %fn = alloca i64, align 8
  store i64 %1, ptr %fn, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %val = alloca i64, align 8
  store i64 0, ptr %val, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  store i64 %calltmp5, ptr %val, align 8
  %6 = load i64, ptr %fn, align 8
  %clo_box = inttoptr i64 %6 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %6, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %7 = load i64, ptr %val, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %7)
  %8 = load i64, ptr %i, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  %blk_rel_load = load i64, ptr %val, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %val, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  ret void
}

declare i64 @List_filter(i64, i64)

define i64 @List_i32_filter(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %result = alloca i64, align 8
  store i64 0, ptr %result, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %val = alloca i64, align 8
  store i64 0, ptr %val, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_i32_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %result, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %val, align 8
  %6 = load i64, ptr %pred, align 8
  %clo_box = inttoptr i64 %6 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %6, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %7 = load i64, ptr %val, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %7)
  %ifcond = icmp ne i64 %closure_call, 0
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  %8 = load i64, ptr %result, align 8
  call void @nova_retain(i64 %8)
  %var_rel_load = load i64, ptr %result, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_i32)
  ret i64 %8

then:                                             ; preds = %while_body
  %9 = load i64, ptr %result, align 8
  %10 = load i64, ptr %val, align 8
  call void @List_i32_push(i64 %9, i64 %10)
  br label %ifcont

ifcont:                                           ; preds = %then, %while_body
  %11 = load i64, ptr %i, align 8
  %addtmp = add i64 %11, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

define i64 @List_string_filter(i64 %0, i64 %1) {
entry:
  %tmp_slot6 = alloca i64, align 8
  store i64 0, ptr %tmp_slot6, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %result = alloca i64, align 8
  store i64 0, ptr %result, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %val = alloca i64, align 8
  store i64 0, ptr %val, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_string_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %result, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %tmp_slot6, align 8
  store i64 %calltmp5, ptr %val, align 8
  %6 = load i64, ptr %pred, align 8
  %clo_box = inttoptr i64 %6 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %6, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %7 = load i64, ptr %val, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %7)
  %ifcond = icmp ne i64 %closure_call, 0
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  %8 = load i64, ptr %result, align 8
  call void @nova_retain(i64 %8)
  %var_rel_load = load i64, ptr %result, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_string)
  ret i64 %8

then:                                             ; preds = %while_body
  %9 = load i64, ptr %result, align 8
  %10 = load i64, ptr %val, align 8
  call void @List_string_push(i64 %9, i64 %10)
  br label %ifcont

ifcont:                                           ; preds = %then, %while_body
  %11 = load i64, ptr %i, align 8
  %addtmp = add i64 %11, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  %blk_rel_load = load i64, ptr %val, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %val, align 8
  br label %while_cond
}

declare void @List_reverse(i64)

define void @List_i32_reverse(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %tmp = alloca i64, align 8
  store i64 0, ptr %tmp, align 8
  store i64 0, ptr %i, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %subtmp = sub i64 %calltmp, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %j, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %j, align 8
  %cmptmp = icmp slt i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %tmp, align 8
  %6 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %6, 0
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %field_val8 = load ptr, ptr %field_ptr7, align 8
  %ptr_to_int9 = ptrtoint ptr %field_val8 to i64
  %7 = load i64, ptr %i, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr10 = add i64 %8, 0
  %field_ptr11 = inttoptr i64 %field_addr10 to ptr
  %field_val12 = load ptr, ptr %field_ptr11, align 8
  %ptr_to_int13 = ptrtoint ptr %field_val12 to i64
  %9 = load i64, ptr %j, align 8
  %calltmp14 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int13, i64 %9)
  call void @RawBuffer_i32_set(i64 %ptr_to_int9, i64 %7, i64 %calltmp14)
  %10 = load i64, ptr %self, align 8
  %field_addr15 = add i64 %10, 0
  %field_ptr16 = inttoptr i64 %field_addr15 to ptr
  %field_val17 = load ptr, ptr %field_ptr16, align 8
  %ptr_to_int18 = ptrtoint ptr %field_val17 to i64
  %11 = load i64, ptr %j, align 8
  %12 = load i64, ptr %tmp, align 8
  call void @RawBuffer_i32_set(i64 %ptr_to_int18, i64 %11, i64 %12)
  %13 = load i64, ptr %i, align 8
  %addtmp = add i64 %13, 1
  %int_trunc19 = trunc i64 %addtmp to i32
  %int_sext20 = sext i32 %int_trunc19 to i64
  store i64 %int_sext20, ptr %i, align 8
  %14 = load i64, ptr %j, align 8
  %subtmp21 = sub i64 %14, 1
  %int_trunc22 = trunc i64 %subtmp21 to i32
  %int_sext23 = sext i32 %int_trunc22 to i64
  store i64 %int_sext23, ptr %j, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  ret void
}

define void @List_string_reverse(i64 %0) {
entry:
  %tmp_slot15 = alloca i64, align 8
  store i64 0, ptr %tmp_slot15, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %tmp = alloca i64, align 8
  store i64 0, ptr %tmp, align 8
  store i64 0, ptr %i, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %subtmp = sub i64 %calltmp, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %j, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %j, align 8
  %cmptmp = icmp slt i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  store i64 %calltmp5, ptr %tmp, align 8
  %6 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %6, 0
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %field_val8 = load ptr, ptr %field_ptr7, align 8
  %ptr_to_int9 = ptrtoint ptr %field_val8 to i64
  %7 = load i64, ptr %i, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr10 = add i64 %8, 0
  %field_ptr11 = inttoptr i64 %field_addr10 to ptr
  %field_val12 = load ptr, ptr %field_ptr11, align 8
  %ptr_to_int13 = ptrtoint ptr %field_val12 to i64
  %9 = load i64, ptr %j, align 8
  %calltmp14 = call i64 @RawBuffer_string_at(i64 %ptr_to_int13, i64 %9)
  store i64 %calltmp14, ptr %tmp_slot15, align 8
  call void @RawBuffer_string_set(i64 %ptr_to_int9, i64 %7, i64 %calltmp14)
  %tmp_rel = load i64, ptr %tmp_slot15, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot15, align 8
  %10 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %10, 0
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %field_val18 = load ptr, ptr %field_ptr17, align 8
  %ptr_to_int19 = ptrtoint ptr %field_val18 to i64
  %11 = load i64, ptr %j, align 8
  %12 = load i64, ptr %tmp, align 8
  call void @RawBuffer_string_set(i64 %ptr_to_int19, i64 %11, i64 %12)
  %13 = load i64, ptr %i, align 8
  %addtmp = add i64 %13, 1
  %int_trunc20 = trunc i64 %addtmp to i32
  %int_sext21 = sext i32 %int_trunc20 to i64
  store i64 %int_sext21, ptr %i, align 8
  %14 = load i64, ptr %j, align 8
  %subtmp22 = sub i64 %14, 1
  %int_trunc23 = trunc i64 %subtmp22 to i32
  %int_sext24 = sext i32 %int_trunc23 to i64
  store i64 %int_sext24, ptr %j, align 8
  %blk_rel_load = load i64, ptr %tmp, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %tmp, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  ret void
}

declare void @List_clear(i64)

define void @List_i32_clear(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  call void @RawBuffer_i32_clear(i64 %ptr_to_int)
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  ret void
}

define void @List_string_clear(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  call void @RawBuffer_string_clear(i64 %ptr_to_int)
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  ret void
}

declare i64 @List_first(i64)

define i64 @List_i32_first(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 0)
  %valopt_box = call i64 @nova_valopt_box(i64 %calltmp5)
  ret i64 %valopt_box
}

define i64 @List_string_first(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 0)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  ret i64 %calltmp5
}

declare i64 @List_last(i64)

define i64 @List_i32_last(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %3 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %3, 0
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %field_val7 = load ptr, ptr %field_ptr6, align 8
  %ptr_to_int8 = ptrtoint ptr %field_val7 to i64
  %calltmp9 = call i64 @RawBuffer_i32_count(i64 %ptr_to_int8)
  %subtmp = sub i64 %calltmp9, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %calltmp10 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %int_sext)
  %valopt_box = call i64 @nova_valopt_box(i64 %calltmp10)
  ret i64 %valopt_box
}

define i64 @List_string_last(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %3 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %3, 0
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %field_val7 = load ptr, ptr %field_ptr6, align 8
  %ptr_to_int8 = ptrtoint ptr %field_val7 to i64
  %calltmp9 = call i64 @RawBuffer_string_count(i64 %ptr_to_int8)
  %subtmp = sub i64 %calltmp9, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %calltmp10 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %int_sext)
  store i64 %calltmp10, ptr %tmp_slot, align 8
  ret i64 %calltmp10
}

declare i64 @List_pop(i64)

define i64 @List_i32_pop(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %v = alloca i64, align 8
  store i64 0, ptr %v, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_pop(i64 %ptr_to_int)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %v, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp5 = call i64 @RawBuffer_i32_count(i64 %ptr_to_int4)
  %3 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %3, 8
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %trunc = trunc i64 %calltmp5 to i32
  store i32 %trunc, ptr %field_ptr7, align 4
  %4 = load i64, ptr %self, align 8
  %field_addr8 = add i64 %4, 0
  %field_ptr9 = inttoptr i64 %field_addr8 to ptr
  %field_val10 = load ptr, ptr %field_ptr9, align 8
  %ptr_to_int11 = ptrtoint ptr %field_val10 to i64
  %calltmp12 = call i64 @RawBuffer_i32_capacity(i64 %ptr_to_int11)
  %5 = load i64, ptr %self, align 8
  %field_addr13 = add i64 %5, 12
  %field_ptr14 = inttoptr i64 %field_addr13 to ptr
  %trunc15 = trunc i64 %calltmp12 to i32
  store i32 %trunc15, ptr %field_ptr14, align 4
  %6 = load i64, ptr %v, align 8
  call void @nova_retain(i64 %6)
  %var_rel_load = load i64, ptr %v, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %6
}

define i64 @List_string_pop(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %v = alloca i64, align 8
  store i64 0, ptr %v, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_pop(i64 %ptr_to_int)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %v, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %calltmp5 = call i64 @RawBuffer_string_count(i64 %ptr_to_int4)
  %3 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %3, 8
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %trunc = trunc i64 %calltmp5 to i32
  store i32 %trunc, ptr %field_ptr7, align 4
  %4 = load i64, ptr %self, align 8
  %field_addr8 = add i64 %4, 0
  %field_ptr9 = inttoptr i64 %field_addr8 to ptr
  %field_val10 = load ptr, ptr %field_ptr9, align 8
  %ptr_to_int11 = ptrtoint ptr %field_val10 to i64
  %calltmp12 = call i64 @RawBuffer_string_capacity(i64 %ptr_to_int11)
  %5 = load i64, ptr %self, align 8
  %field_addr13 = add i64 %5, 12
  %field_ptr14 = inttoptr i64 %field_addr13 to ptr
  %trunc15 = trunc i64 %calltmp12 to i32
  store i32 %trunc15, ptr %field_ptr14, align 4
  %6 = load i64, ptr %v, align 8
  call void @nova_retain(i64 %6)
  %var_rel_load = load i64, ptr %v, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %6
}

declare i64 @List_findIndex(i64, i64)

define i64 @List_i32_findIndex(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %pred, align 8
  %clo_box = inttoptr i64 %4 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %4, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %6)
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %calltmp5)
  %ifcond = icmp ne i64 %closure_call, 0
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  ret i64 -1

then:                                             ; preds = %while_body
  %7 = load i64, ptr %i, align 8
  ret i64 %7

ifcont:                                           ; preds = %while_body
  %8 = load i64, ptr %i, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

define i64 @List_string_findIndex(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %pred, align 8
  %clo_box = inttoptr i64 %4 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %4, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %6)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %calltmp5)
  %ifcond = icmp ne i64 %closure_call, 0
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  ret i64 -1

then:                                             ; preds = %while_body
  %7 = load i64, ptr %i, align 8
  ret i64 %7

ifcont:                                           ; preds = %while_body
  %8 = load i64, ptr %i, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

declare i64 @List_any(i64, i64)

define i64 @List_i32_any(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %pred, align 8
  %calltmp = call i64 @List_i32_findIndex(i64 %2, i64 %3)
  %cmptmp = icmp ne i64 %calltmp, -1
  %zexttmp = zext i1 %cmptmp to i64
  ret i64 %zexttmp
}

define i64 @List_string_any(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %pred, align 8
  %calltmp = call i64 @List_string_findIndex(i64 %2, i64 %3)
  %cmptmp = icmp ne i64 %calltmp, -1
  %zexttmp = zext i1 %cmptmp to i64
  ret i64 %zexttmp
}

declare i64 @List_all(i64, i64)

define i64 @List_i32_all(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %pred, align 8
  %clo_box = inttoptr i64 %4 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %4, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %6)
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %calltmp5)
  %nottmp = icmp eq i64 %closure_call, 0
  %zexttmp6 = zext i1 %nottmp to i64
  %ifcond = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  ret i64 1

then:                                             ; preds = %while_body
  ret i64 0

ifcont:                                           ; preds = %while_body
  %7 = load i64, ptr %i, align 8
  %addtmp = add i64 %7, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

define i64 @List_string_all(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %pred = alloca i64, align 8
  store i64 %1, ptr %pred, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %pred, align 8
  %clo_box = inttoptr i64 %4 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %4, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %6)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %calltmp5)
  %nottmp = icmp eq i64 %closure_call, 0
  %zexttmp6 = zext i1 %nottmp to i64
  %ifcond = icmp ne i64 %zexttmp6, 0
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  ret i64 1

then:                                             ; preds = %while_body
  ret i64 0

ifcont:                                           ; preds = %while_body
  %7 = load i64, ptr %i, align 8
  %addtmp = add i64 %7, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

declare i64 @List_indexOf(i64, i64)

define i64 @List_i32_indexOf(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %5)
  %6 = load i64, ptr %value, align 8
  %cmptmp6 = icmp eq i64 %calltmp5, %6
  %zexttmp7 = zext i1 %cmptmp6 to i64
  %ifcond = icmp ne i64 %zexttmp7, 0
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  ret i64 -1

then:                                             ; preds = %while_body
  %7 = load i64, ptr %i, align 8
  ret i64 %7

ifcont:                                           ; preds = %while_body
  %8 = load i64, ptr %i, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

define i64 @List_string_indexOf(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %5 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %5)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  %6 = load i64, ptr %value, align 8
  %eql_tmp = call i64 @string_eql(i64 %calltmp5, i64 %6)
  %ifcond = icmp ne i64 %eql_tmp, 0
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %while_cond
  ret i64 -1

then:                                             ; preds = %while_body
  %7 = load i64, ptr %i, align 8
  ret i64 %7

ifcont:                                           ; preds = %while_body
  %8 = load i64, ptr %i, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

declare i64 @List_contains(i64, i64)

define i64 @List_i32_contains(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %value, align 8
  %calltmp = call i64 @List_i32_indexOf(i64 %2, i64 %3)
  %cmptmp = icmp ne i64 %calltmp, -1
  %zexttmp = zext i1 %cmptmp to i64
  ret i64 %zexttmp
}

define i64 @List_string_contains(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %value = alloca i64, align 8
  store i64 %1, ptr %value, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %value, align 8
  %calltmp = call i64 @List_string_indexOf(i64 %2, i64 %3)
  %cmptmp = icmp ne i64 %calltmp, -1
  %zexttmp = zext i1 %cmptmp to i64
  ret i64 %zexttmp
}

declare i64 @List_slice(i64, i64, i64)

define i64 @List_i32_slice(i64 %0, i64 %1, i64 %2) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %start = alloca i64, align 8
  store i64 %1, ptr %start, align 8
  %end = alloca i64, align 8
  store i64 %2, ptr %end, align 8
  %n = alloca i64, align 8
  store i64 0, ptr %n, align 8
  %s = alloca i64, align 8
  store i64 0, ptr %s, align 8
  %e = alloca i64, align 8
  store i64 0, ptr %e, align 8
  %out = alloca i64, align 8
  store i64 0, ptr %out, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  store i64 %calltmp, ptr %n, align 8
  %4 = load i64, ptr %start, align 8
  %cmptmp = icmp slt i64 %4, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  br label %ifcont

else:                                             ; preds = %entry
  %5 = load i64, ptr %start, align 8
  %6 = load i64, ptr %n, align 8
  %cmptmp1 = icmp sgt i64 %5, %6
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ifcond3 = icmp ne i64 %zexttmp2, 0
  br i1 %ifcond3, label %then4, label %else5

ifcont:                                           ; preds = %ifcont6, %then
  %ifphi7 = phi i64 [ 0, %then ], [ %ifphi, %ifcont6 ]
  store i64 %ifphi7, ptr %s, align 8
  %7 = load i64, ptr %end, align 8
  %cmptmp8 = icmp slt i64 %7, 0
  %zexttmp9 = zext i1 %cmptmp8 to i64
  %ifcond10 = icmp ne i64 %zexttmp9, 0
  br i1 %ifcond10, label %then11, label %else12

then4:                                            ; preds = %else
  %8 = load i64, ptr %n, align 8
  br label %ifcont6

else5:                                            ; preds = %else
  %9 = load i64, ptr %start, align 8
  br label %ifcont6

ifcont6:                                          ; preds = %else5, %then4
  %ifphi = phi i64 [ %8, %then4 ], [ %9, %else5 ]
  br label %ifcont

then11:                                           ; preds = %ifcont
  br label %ifcont13

else12:                                           ; preds = %ifcont
  %10 = load i64, ptr %end, align 8
  %11 = load i64, ptr %n, align 8
  %cmptmp14 = icmp sgt i64 %10, %11
  %zexttmp15 = zext i1 %cmptmp14 to i64
  %ifcond16 = icmp ne i64 %zexttmp15, 0
  br i1 %ifcond16, label %then17, label %else18

ifcont13:                                         ; preds = %ifcont19, %then11
  %ifphi21 = phi i64 [ 0, %then11 ], [ %ifphi20, %ifcont19 ]
  store i64 %ifphi21, ptr %e, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_i32_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %out, align 8
  %12 = load i64, ptr %s, align 8
  store i64 %12, ptr %i, align 8
  br label %while_cond

then17:                                           ; preds = %else12
  %13 = load i64, ptr %n, align 8
  br label %ifcont19

else18:                                           ; preds = %else12
  %14 = load i64, ptr %end, align 8
  br label %ifcont19

ifcont19:                                         ; preds = %else18, %then17
  %ifphi20 = phi i64 [ %13, %then17 ], [ %14, %else18 ]
  br label %ifcont13

while_cond:                                       ; preds = %while_body, %ifcont13
  %15 = load i64, ptr %i, align 8
  %16 = load i64, ptr %e, align 8
  %cmptmp22 = icmp slt i64 %15, %16
  %zexttmp23 = zext i1 %cmptmp22 to i64
  %whilecond = icmp ne i64 %zexttmp23, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %17 = load i64, ptr %out, align 8
  %18 = load i64, ptr %self, align 8
  %field_addr24 = add i64 %18, 0
  %field_ptr25 = inttoptr i64 %field_addr24 to ptr
  %field_val26 = load ptr, ptr %field_ptr25, align 8
  %ptr_to_int27 = ptrtoint ptr %field_val26 to i64
  %19 = load i64, ptr %i, align 8
  %calltmp28 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int27, i64 %19)
  call void @List_i32_push(i64 %17, i64 %calltmp28)
  %20 = load i64, ptr %i, align 8
  %addtmp = add i64 %20, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %21 = load i64, ptr %out, align 8
  call void @nova_retain(i64 %21)
  %var_rel_load = load i64, ptr %out, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_i32)
  ret i64 %21
}

define i64 @List_string_slice(i64 %0, i64 %1, i64 %2) {
entry:
  %tmp_slot29 = alloca i64, align 8
  store i64 0, ptr %tmp_slot29, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %start = alloca i64, align 8
  store i64 %1, ptr %start, align 8
  %end = alloca i64, align 8
  store i64 %2, ptr %end, align 8
  %n = alloca i64, align 8
  store i64 0, ptr %n, align 8
  %s = alloca i64, align 8
  store i64 0, ptr %s, align 8
  %e = alloca i64, align 8
  store i64 0, ptr %e, align 8
  %out = alloca i64, align 8
  store i64 0, ptr %out, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  store i64 %calltmp, ptr %n, align 8
  %4 = load i64, ptr %start, align 8
  %cmptmp = icmp slt i64 %4, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  br label %ifcont

else:                                             ; preds = %entry
  %5 = load i64, ptr %start, align 8
  %6 = load i64, ptr %n, align 8
  %cmptmp1 = icmp sgt i64 %5, %6
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ifcond3 = icmp ne i64 %zexttmp2, 0
  br i1 %ifcond3, label %then4, label %else5

ifcont:                                           ; preds = %ifcont6, %then
  %ifphi7 = phi i64 [ 0, %then ], [ %ifphi, %ifcont6 ]
  store i64 %ifphi7, ptr %s, align 8
  %7 = load i64, ptr %end, align 8
  %cmptmp8 = icmp slt i64 %7, 0
  %zexttmp9 = zext i1 %cmptmp8 to i64
  %ifcond10 = icmp ne i64 %zexttmp9, 0
  br i1 %ifcond10, label %then11, label %else12

then4:                                            ; preds = %else
  %8 = load i64, ptr %n, align 8
  br label %ifcont6

else5:                                            ; preds = %else
  %9 = load i64, ptr %start, align 8
  br label %ifcont6

ifcont6:                                          ; preds = %else5, %then4
  %ifphi = phi i64 [ %8, %then4 ], [ %9, %else5 ]
  br label %ifcont

then11:                                           ; preds = %ifcont
  br label %ifcont13

else12:                                           ; preds = %ifcont
  %10 = load i64, ptr %end, align 8
  %11 = load i64, ptr %n, align 8
  %cmptmp14 = icmp sgt i64 %10, %11
  %zexttmp15 = zext i1 %cmptmp14 to i64
  %ifcond16 = icmp ne i64 %zexttmp15, 0
  br i1 %ifcond16, label %then17, label %else18

ifcont13:                                         ; preds = %ifcont19, %then11
  %ifphi21 = phi i64 [ 0, %then11 ], [ %ifphi20, %ifcont19 ]
  store i64 %ifphi21, ptr %e, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_string_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %out, align 8
  %12 = load i64, ptr %s, align 8
  store i64 %12, ptr %i, align 8
  br label %while_cond

then17:                                           ; preds = %else12
  %13 = load i64, ptr %n, align 8
  br label %ifcont19

else18:                                           ; preds = %else12
  %14 = load i64, ptr %end, align 8
  br label %ifcont19

ifcont19:                                         ; preds = %else18, %then17
  %ifphi20 = phi i64 [ %13, %then17 ], [ %14, %else18 ]
  br label %ifcont13

while_cond:                                       ; preds = %while_body, %ifcont13
  %15 = load i64, ptr %i, align 8
  %16 = load i64, ptr %e, align 8
  %cmptmp22 = icmp slt i64 %15, %16
  %zexttmp23 = zext i1 %cmptmp22 to i64
  %whilecond = icmp ne i64 %zexttmp23, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %17 = load i64, ptr %out, align 8
  %18 = load i64, ptr %self, align 8
  %field_addr24 = add i64 %18, 0
  %field_ptr25 = inttoptr i64 %field_addr24 to ptr
  %field_val26 = load ptr, ptr %field_ptr25, align 8
  %ptr_to_int27 = ptrtoint ptr %field_val26 to i64
  %19 = load i64, ptr %i, align 8
  %calltmp28 = call i64 @RawBuffer_string_at(i64 %ptr_to_int27, i64 %19)
  store i64 %calltmp28, ptr %tmp_slot29, align 8
  call void @List_string_push(i64 %17, i64 %calltmp28)
  %tmp_rel = load i64, ptr %tmp_slot29, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot29, align 8
  %20 = load i64, ptr %i, align 8
  %addtmp = add i64 %20, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %21 = load i64, ptr %out, align 8
  call void @nova_retain(i64 %21)
  %var_rel_load = load i64, ptr %out, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_string)
  ret i64 %21
}

declare i64 @List_concat(i64, i64)

define i64 @List_i32_concat(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %other = alloca i64, align 8
  store i64 %1, ptr %other, align 8
  %out = alloca i64, align 8
  store i64 0, ptr %out, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_i32_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %out, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %out, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %6)
  call void @List_i32_push(i64 %4, i64 %calltmp5)
  %7 = load i64, ptr %i, align 8
  %addtmp = add i64 %7, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  store i64 0, ptr %j, align 8
  br label %while_cond6

while_cond6:                                      ; preds = %while_body7, %while_exit
  %8 = load i64, ptr %j, align 8
  %9 = load i64, ptr %other, align 8
  %calltmp9 = call i64 @List_i32_size(i64 %9)
  %cmptmp10 = icmp slt i64 %8, %calltmp9
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %whilecond12 = icmp ne i64 %zexttmp11, 0
  br i1 %whilecond12, label %while_body7, label %while_exit8

while_body7:                                      ; preds = %while_cond6
  %10 = load i64, ptr %out, align 8
  %11 = load i64, ptr %other, align 8
  %12 = load i64, ptr %j, align 8
  %calltmp13 = call i64 @List_i32_at(i64 %11, i64 %12)
  call void @List_i32_push(i64 %10, i64 %calltmp13)
  %13 = load i64, ptr %j, align 8
  %addtmp14 = add i64 %13, 1
  %int_trunc15 = trunc i64 %addtmp14 to i32
  %int_sext16 = sext i32 %int_trunc15 to i64
  store i64 %int_sext16, ptr %j, align 8
  br label %while_cond6

while_exit8:                                      ; preds = %while_cond6
  %14 = load i64, ptr %out, align 8
  call void @nova_retain(i64 %14)
  %var_rel_load = load i64, ptr %out, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_i32)
  ret i64 %14
}

define i64 @List_string_concat(i64 %0, i64 %1) {
entry:
  %tmp_slot15 = alloca i64, align 8
  store i64 0, ptr %tmp_slot15, align 8
  %tmp_slot6 = alloca i64, align 8
  store i64 0, ptr %tmp_slot6, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %other = alloca i64, align 8
  store i64 %1, ptr %other, align 8
  %out = alloca i64, align 8
  store i64 0, ptr %out, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_string_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %out, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  %cmptmp = icmp slt i64 %2, %calltmp
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %out, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %6)
  store i64 %calltmp5, ptr %tmp_slot6, align 8
  call void @List_string_push(i64 %4, i64 %calltmp5)
  %tmp_rel = load i64, ptr %tmp_slot6, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot6, align 8
  %7 = load i64, ptr %i, align 8
  %addtmp = add i64 %7, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  store i64 0, ptr %j, align 8
  br label %while_cond7

while_cond7:                                      ; preds = %while_body8, %while_exit
  %8 = load i64, ptr %j, align 8
  %9 = load i64, ptr %other, align 8
  %calltmp10 = call i64 @List_string_size(i64 %9)
  %cmptmp11 = icmp slt i64 %8, %calltmp10
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %whilecond13 = icmp ne i64 %zexttmp12, 0
  br i1 %whilecond13, label %while_body8, label %while_exit9

while_body8:                                      ; preds = %while_cond7
  %10 = load i64, ptr %out, align 8
  %11 = load i64, ptr %other, align 8
  %12 = load i64, ptr %j, align 8
  %calltmp14 = call i64 @List_string_at(i64 %11, i64 %12)
  store i64 %calltmp14, ptr %tmp_slot15, align 8
  call void @List_string_push(i64 %10, i64 %calltmp14)
  %tmp_rel16 = load i64, ptr %tmp_slot15, align 8
  call void @nova_release(i64 %tmp_rel16, ptr null)
  store i64 0, ptr %tmp_slot15, align 8
  %13 = load i64, ptr %j, align 8
  %addtmp17 = add i64 %13, 1
  %int_trunc18 = trunc i64 %addtmp17 to i32
  %int_sext19 = sext i32 %int_trunc18 to i64
  store i64 %int_sext19, ptr %j, align 8
  br label %while_cond7

while_exit9:                                      ; preds = %while_cond7
  %14 = load i64, ptr %out, align 8
  call void @nova_retain(i64 %14)
  %var_rel_load = load i64, ptr %out, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_string)
  ret i64 %14
}

declare void @List_sort(i64, i64)

define void @List_i32_sort(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %cmp = alloca i64, align 8
  store i64 %1, ptr %cmp, align 8
  %n = alloca i64, align 8
  store i64 0, ptr %n, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %key = alloca i64, align 8
  store i64 0, ptr %key, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_i32_count(i64 %ptr_to_int)
  store i64 %calltmp, ptr %n, align 8
  store i64 1, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_exit8, %entry
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %n, align 8
  %cmptmp = icmp slt i64 %3, %4
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int4, i64 %6)
  store i64 %calltmp5, ptr %key, align 8
  %7 = load i64, ptr %i, align 8
  %subtmp = sub i64 %7, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %j, align 8
  br label %while_cond6

while_exit:                                       ; preds = %while_cond
  ret void

while_cond6:                                      ; preds = %while_body7, %while_body
  %8 = load i64, ptr %j, align 8
  %cmptmp9 = icmp sge i64 %8, 0
  %zexttmp10 = zext i1 %cmptmp9 to i64
  %9 = load i64, ptr %cmp, align 8
  %clo_box = inttoptr i64 %9 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %9, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %10 = load i64, ptr %self, align 8
  %field_addr11 = add i64 %10, 0
  %field_ptr12 = inttoptr i64 %field_addr11 to ptr
  %field_val13 = load ptr, ptr %field_ptr12, align 8
  %ptr_to_int14 = ptrtoint ptr %field_val13 to i64
  %11 = load i64, ptr %j, align 8
  %calltmp15 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int14, i64 %11)
  %12 = load i64, ptr %key, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %calltmp15, i64 %12)
  %cmptmp16 = icmp sgt i64 %closure_call, 0
  %zexttmp17 = zext i1 %cmptmp16 to i64
  %andtmp = and i64 %zexttmp10, %zexttmp17
  %whilecond18 = icmp ne i64 %andtmp, 0
  br i1 %whilecond18, label %while_body7, label %while_exit8

while_body7:                                      ; preds = %while_cond6
  %13 = load i64, ptr %self, align 8
  %field_addr19 = add i64 %13, 0
  %field_ptr20 = inttoptr i64 %field_addr19 to ptr
  %field_val21 = load ptr, ptr %field_ptr20, align 8
  %ptr_to_int22 = ptrtoint ptr %field_val21 to i64
  %14 = load i64, ptr %j, align 8
  %addtmp = add i64 %14, 1
  %int_trunc23 = trunc i64 %addtmp to i32
  %int_sext24 = sext i32 %int_trunc23 to i64
  %15 = load i64, ptr %self, align 8
  %field_addr25 = add i64 %15, 0
  %field_ptr26 = inttoptr i64 %field_addr25 to ptr
  %field_val27 = load ptr, ptr %field_ptr26, align 8
  %ptr_to_int28 = ptrtoint ptr %field_val27 to i64
  %16 = load i64, ptr %j, align 8
  %calltmp29 = call i64 @RawBuffer_i32_at(i64 %ptr_to_int28, i64 %16)
  call void @RawBuffer_i32_set(i64 %ptr_to_int22, i64 %int_sext24, i64 %calltmp29)
  %17 = load i64, ptr %j, align 8
  %subtmp30 = sub i64 %17, 1
  %int_trunc31 = trunc i64 %subtmp30 to i32
  %int_sext32 = sext i32 %int_trunc31 to i64
  store i64 %int_sext32, ptr %j, align 8
  br label %while_cond6

while_exit8:                                      ; preds = %while_cond6
  %18 = load i64, ptr %self, align 8
  %field_addr33 = add i64 %18, 0
  %field_ptr34 = inttoptr i64 %field_addr33 to ptr
  %field_val35 = load ptr, ptr %field_ptr34, align 8
  %ptr_to_int36 = ptrtoint ptr %field_val35 to i64
  %19 = load i64, ptr %j, align 8
  %addtmp37 = add i64 %19, 1
  %int_trunc38 = trunc i64 %addtmp37 to i32
  %int_sext39 = sext i32 %int_trunc38 to i64
  %20 = load i64, ptr %key, align 8
  call void @RawBuffer_i32_set(i64 %ptr_to_int36, i64 %int_sext39, i64 %20)
  %21 = load i64, ptr %i, align 8
  %addtmp40 = add i64 %21, 1
  %int_trunc41 = trunc i64 %addtmp40 to i32
  %int_sext42 = sext i32 %int_trunc41 to i64
  store i64 %int_sext42, ptr %i, align 8
  br label %while_cond
}

define void @List_string_sort(i64 %0, i64 %1) {
entry:
  %tmp_slot31 = alloca i64, align 8
  store i64 0, ptr %tmp_slot31, align 8
  %tmp_slot16 = alloca i64, align 8
  store i64 0, ptr %tmp_slot16, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %cmp = alloca i64, align 8
  store i64 %1, ptr %cmp, align 8
  %n = alloca i64, align 8
  store i64 0, ptr %n, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %key = alloca i64, align 8
  store i64 0, ptr %key, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %2 = load i64, ptr %self, align 8
  %field_addr = add i64 %2, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_val to i64
  %calltmp = call i64 @RawBuffer_string_count(i64 %ptr_to_int)
  store i64 %calltmp, ptr %n, align 8
  store i64 1, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_exit8, %entry
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %n, align 8
  %cmptmp = icmp slt i64 %3, %4
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %5 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %5, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load ptr, ptr %field_ptr2, align 8
  %ptr_to_int4 = ptrtoint ptr %field_val3 to i64
  %6 = load i64, ptr %i, align 8
  %calltmp5 = call i64 @RawBuffer_string_at(i64 %ptr_to_int4, i64 %6)
  store i64 %calltmp5, ptr %tmp_slot, align 8
  store i64 %calltmp5, ptr %key, align 8
  %7 = load i64, ptr %i, align 8
  %subtmp = sub i64 %7, 1
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %j, align 8
  br label %while_cond6

while_exit:                                       ; preds = %while_cond
  ret void

while_cond6:                                      ; preds = %while_body7, %while_body
  %8 = load i64, ptr %j, align 8
  %cmptmp9 = icmp sge i64 %8, 0
  %zexttmp10 = zext i1 %cmptmp9 to i64
  %9 = load i64, ptr %cmp, align 8
  %clo_box = inttoptr i64 %9 to ptr
  %clo_fn = load i64, ptr %clo_box, align 8
  %clo_env_addr = add i64 %9, 8
  %clo_env_ptr = inttoptr i64 %clo_env_addr to ptr
  %clo_env = load i64, ptr %clo_env_ptr, align 8
  %clo_fn_ptr = inttoptr i64 %clo_fn to ptr
  %10 = load i64, ptr %self, align 8
  %field_addr11 = add i64 %10, 0
  %field_ptr12 = inttoptr i64 %field_addr11 to ptr
  %field_val13 = load ptr, ptr %field_ptr12, align 8
  %ptr_to_int14 = ptrtoint ptr %field_val13 to i64
  %11 = load i64, ptr %j, align 8
  %calltmp15 = call i64 @RawBuffer_string_at(i64 %ptr_to_int14, i64 %11)
  store i64 %calltmp15, ptr %tmp_slot16, align 8
  %12 = load i64, ptr %key, align 8
  %closure_call = call i64 %clo_fn_ptr(i64 %clo_env, i64 %calltmp15, i64 %12)
  %cmptmp17 = icmp sgt i64 %closure_call, 0
  %zexttmp18 = zext i1 %cmptmp17 to i64
  %andtmp = and i64 %zexttmp10, %zexttmp18
  %whilecond19 = icmp ne i64 %andtmp, 0
  br i1 %whilecond19, label %while_body7, label %while_exit8

while_body7:                                      ; preds = %while_cond6
  %13 = load i64, ptr %self, align 8
  %field_addr20 = add i64 %13, 0
  %field_ptr21 = inttoptr i64 %field_addr20 to ptr
  %field_val22 = load ptr, ptr %field_ptr21, align 8
  %ptr_to_int23 = ptrtoint ptr %field_val22 to i64
  %14 = load i64, ptr %j, align 8
  %addtmp = add i64 %14, 1
  %int_trunc24 = trunc i64 %addtmp to i32
  %int_sext25 = sext i32 %int_trunc24 to i64
  %15 = load i64, ptr %self, align 8
  %field_addr26 = add i64 %15, 0
  %field_ptr27 = inttoptr i64 %field_addr26 to ptr
  %field_val28 = load ptr, ptr %field_ptr27, align 8
  %ptr_to_int29 = ptrtoint ptr %field_val28 to i64
  %16 = load i64, ptr %j, align 8
  %calltmp30 = call i64 @RawBuffer_string_at(i64 %ptr_to_int29, i64 %16)
  store i64 %calltmp30, ptr %tmp_slot31, align 8
  call void @RawBuffer_string_set(i64 %ptr_to_int23, i64 %int_sext25, i64 %calltmp30)
  %tmp_rel = load i64, ptr %tmp_slot31, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot31, align 8
  %17 = load i64, ptr %j, align 8
  %subtmp32 = sub i64 %17, 1
  %int_trunc33 = trunc i64 %subtmp32 to i32
  %int_sext34 = sext i32 %int_trunc33 to i64
  store i64 %int_sext34, ptr %j, align 8
  br label %while_cond6

while_exit8:                                      ; preds = %while_cond6
  %tmp_rel35 = load i64, ptr %tmp_slot16, align 8
  call void @nova_release(i64 %tmp_rel35, ptr null)
  store i64 0, ptr %tmp_slot16, align 8
  %18 = load i64, ptr %self, align 8
  %field_addr36 = add i64 %18, 0
  %field_ptr37 = inttoptr i64 %field_addr36 to ptr
  %field_val38 = load ptr, ptr %field_ptr37, align 8
  %ptr_to_int39 = ptrtoint ptr %field_val38 to i64
  %19 = load i64, ptr %j, align 8
  %addtmp40 = add i64 %19, 1
  %int_trunc41 = trunc i64 %addtmp40 to i32
  %int_sext42 = sext i32 %int_trunc41 to i64
  %20 = load i64, ptr %key, align 8
  call void @RawBuffer_string_set(i64 %ptr_to_int39, i64 %int_sext42, i64 %20)
  %21 = load i64, ptr %i, align 8
  %addtmp43 = add i64 %21, 1
  %int_trunc44 = trunc i64 %addtmp43 to i32
  %int_sext45 = sext i32 %int_trunc44 to i64
  store i64 %int_sext45, ptr %i, align 8
  %blk_rel_load = load i64, ptr %key, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %key, align 8
  br label %while_cond
}

define void @StringBuilder_init(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  store i32 16, ptr %field_ptr, align 4
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  store i32 0, ptr %field_ptr2, align 4
  %alloc_persistent_nz_tmp = call i64 @nova_bytes_alloc_persistent_nz(i64 16)
  %3 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %3, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  store i64 %alloc_persistent_nz_tmp, ptr %field_ptr4, align 8
  ret void
}

define void @StringBuilder_append(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %s = alloca i64, align 8
  store i64 %1, ptr %s, align 8
  %slen = alloca i64, align 8
  store i64 0, ptr %slen, align 8
  %2 = load i64, ptr %s, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %slen, align 8
  %3 = load i64, ptr %slen, align 8
  %cmptmp = icmp eq i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %4 = load i64, ptr %self, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %6 = load i64, ptr %slen, align 8
  %addtmp = add i64 %sext, %6
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  call void @StringBuilder_ensureCapacity(i64 %4, i64 %int_sext)
  %7 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %7, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr4 = add i64 %8, 8
  %field_ptr5 = inttoptr i64 %field_addr4 to ptr
  %field_val6 = load i32, ptr %field_ptr5, align 4
  %sext7 = sext i32 %field_val6 to i64
  %addtmp8 = add i64 %field_val3, %sext7
  %9 = load i64, ptr %s, align 8
  %10 = load i64, ptr %slen, align 8
  call void @nova_bytes_copy(i64 %addtmp8, i64 %9, i64 %10)
  %11 = load i64, ptr %self, align 8
  %field_addr9 = add i64 %11, 8
  %field_ptr10 = inttoptr i64 %field_addr9 to ptr
  %field_val11 = load i32, ptr %field_ptr10, align 4
  %sext12 = sext i32 %field_val11 to i64
  %12 = load i64, ptr %slen, align 8
  %addtmp13 = add i64 %sext12, %12
  %int_trunc14 = trunc i64 %addtmp13 to i32
  %int_sext15 = sext i32 %int_trunc14 to i64
  %13 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %13, 8
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %trunc = trunc i64 %int_sext15 to i32
  store i32 %trunc, ptr %field_ptr17, align 4
  ret void
}

define void @StringBuilder_appendChar(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %c = alloca i64, align 8
  store i64 %1, ptr %c, align 8
  %2 = load i64, ptr %self, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %addtmp = add i64 %sext, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  call void @StringBuilder_ensureCapacity(i64 %2, i64 %int_sext)
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr4 = add i64 %5, 8
  %field_ptr5 = inttoptr i64 %field_addr4 to ptr
  %field_val6 = load i32, ptr %field_ptr5, align 4
  %sext7 = sext i32 %field_val6 to i64
  %6 = load i64, ptr %c, align 8
  %addr = add i64 %field_val3, %sext7
  %write_ptr = inttoptr i64 %addr to ptr
  %byte_val = trunc i64 %6 to i8
  store i8 %byte_val, ptr %write_ptr, align 1
  %7 = load i64, ptr %self, align 8
  %field_addr8 = add i64 %7, 8
  %field_ptr9 = inttoptr i64 %field_addr8 to ptr
  %field_val10 = load i32, ptr %field_ptr9, align 4
  %sext11 = sext i32 %field_val10 to i64
  %addtmp12 = add i64 %sext11, 1
  %int_trunc13 = trunc i64 %addtmp12 to i32
  %int_sext14 = sext i32 %int_trunc13 to i64
  %8 = load i64, ptr %self, align 8
  %field_addr15 = add i64 %8, 8
  %field_ptr16 = inttoptr i64 %field_addr15 to ptr
  %trunc = trunc i64 %int_sext14 to i32
  store i32 %trunc, ptr %field_ptr16, align 4
  ret void
}

define void @StringBuilder_appendRange(i64 %0, i64 %1, i64 %2, i64 %3) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %s = alloca i64, align 8
  store i64 %1, ptr %s, align 8
  %start = alloca i64, align 8
  store i64 %2, ptr %start, align 8
  %end = alloca i64, align 8
  store i64 %3, ptr %end, align 8
  %n = alloca i64, align 8
  store i64 0, ptr %n, align 8
  %4 = load i64, ptr %end, align 8
  %5 = load i64, ptr %start, align 8
  %subtmp = sub i64 %4, %5
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %n, align 8
  %6 = load i64, ptr %n, align 8
  %cmptmp = icmp sle i64 %6, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %7 = load i64, ptr %self, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr = add i64 %8, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %9 = load i64, ptr %n, align 8
  %addtmp = add i64 %sext, %9
  %int_trunc1 = trunc i64 %addtmp to i32
  %int_sext2 = sext i32 %int_trunc1 to i64
  call void @StringBuilder_ensureCapacity(i64 %7, i64 %int_sext2)
  %10 = load i64, ptr %self, align 8
  %field_addr3 = add i64 %10, 0
  %field_ptr4 = inttoptr i64 %field_addr3 to ptr
  %field_val5 = load i64, ptr %field_ptr4, align 8
  %11 = load i64, ptr %self, align 8
  %field_addr6 = add i64 %11, 8
  %field_ptr7 = inttoptr i64 %field_addr6 to ptr
  %field_val8 = load i32, ptr %field_ptr7, align 4
  %sext9 = sext i32 %field_val8 to i64
  %addtmp10 = add i64 %field_val5, %sext9
  %12 = load i64, ptr %s, align 8
  %13 = load i64, ptr %start, align 8
  %addtmp11 = add i64 %12, %13
  %14 = load i64, ptr %n, align 8
  call void @nova_bytes_copy(i64 %addtmp10, i64 %addtmp11, i64 %14)
  %15 = load i64, ptr %self, align 8
  %field_addr12 = add i64 %15, 8
  %field_ptr13 = inttoptr i64 %field_addr12 to ptr
  %field_val14 = load i32, ptr %field_ptr13, align 4
  %sext15 = sext i32 %field_val14 to i64
  %16 = load i64, ptr %n, align 8
  %addtmp16 = add i64 %sext15, %16
  %int_trunc17 = trunc i64 %addtmp16 to i32
  %int_sext18 = sext i32 %int_trunc17 to i64
  %17 = load i64, ptr %self, align 8
  %field_addr19 = add i64 %17, 8
  %field_ptr20 = inttoptr i64 %field_addr19 to ptr
  %trunc = trunc i64 %int_sext18 to i32
  store i32 %trunc, ptr %field_ptr20, align 4
  ret void
}

define void @StringBuilder_appendBytes(i64 %0, i64 %1, i64 %2) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %srcPtr = alloca i64, align 8
  store i64 %1, ptr %srcPtr, align 8
  %n = alloca i64, align 8
  store i64 %2, ptr %n, align 8
  %3 = load i64, ptr %n, align 8
  %cmptmp = icmp sle i64 %3, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %4 = load i64, ptr %self, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr = add i64 %5, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %6 = load i64, ptr %n, align 8
  %addtmp = add i64 %sext, %6
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  call void @StringBuilder_ensureCapacity(i64 %4, i64 %int_sext)
  %7 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %7, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  %8 = load i64, ptr %self, align 8
  %field_addr4 = add i64 %8, 8
  %field_ptr5 = inttoptr i64 %field_addr4 to ptr
  %field_val6 = load i32, ptr %field_ptr5, align 4
  %sext7 = sext i32 %field_val6 to i64
  %addtmp8 = add i64 %field_val3, %sext7
  %9 = load i64, ptr %srcPtr, align 8
  %10 = load i64, ptr %n, align 8
  call void @nova_bytes_copy(i64 %addtmp8, i64 %9, i64 %10)
  %11 = load i64, ptr %self, align 8
  %field_addr9 = add i64 %11, 8
  %field_ptr10 = inttoptr i64 %field_addr9 to ptr
  %field_val11 = load i32, ptr %field_ptr10, align 4
  %sext12 = sext i32 %field_val11 to i64
  %12 = load i64, ptr %n, align 8
  %addtmp13 = add i64 %sext12, %12
  %int_trunc14 = trunc i64 %addtmp13 to i32
  %int_sext15 = sext i32 %int_trunc14 to i64
  %13 = load i64, ptr %self, align 8
  %field_addr16 = add i64 %13, 8
  %field_ptr17 = inttoptr i64 %field_addr16 to ptr
  %trunc = trunc i64 %int_sext15 to i32
  store i32 %trunc, ptr %field_ptr17, align 4
  ret void
}

define i64 @StringBuilder_toString(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %sptr = alloca i64, align 8
  store i64 0, ptr %sptr, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 8
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp eq i64 %sext, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2) to i64)

ifcont:                                           ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 8
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %alloc_persistent_nz_tmp = call i64 @nova_bytes_alloc_persistent_nz(i64 %sext4)
  store i64 %alloc_persistent_nz_tmp, ptr %sptr, align 8
  %3 = load i64, ptr %sptr, align 8
  %4 = load i64, ptr %self, align 8
  %field_addr5 = add i64 %4, 0
  %field_ptr6 = inttoptr i64 %field_addr5 to ptr
  %field_val7 = load i64, ptr %field_ptr6, align 8
  %5 = load i64, ptr %self, align 8
  %field_addr8 = add i64 %5, 8
  %field_ptr9 = inttoptr i64 %field_addr8 to ptr
  %field_val10 = load i32, ptr %field_ptr9, align 4
  %sext11 = sext i32 %field_val10 to i64
  call void @nova_bytes_copy(i64 %3, i64 %field_val7, i64 %sext11)
  %6 = load i64, ptr %sptr, align 8
  ret i64 %6
}

define void @StringBuilder_ensureCapacity(i64 %0, i64 %1) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %minCap = alloca i64, align 8
  store i64 %1, ptr %minCap, align 8
  %newCap = alloca i64, align 8
  store i64 0, ptr %newCap, align 8
  %newBuf = alloca i64, align 8
  store i64 0, ptr %newBuf, align 8
  %2 = load i64, ptr %minCap, align 8
  %3 = load i64, ptr %self, align 8
  %field_addr = add i64 %3, 12
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i32, ptr %field_ptr, align 4
  %sext = sext i32 %field_val to i64
  %cmptmp = icmp sle i64 %2, %sext
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret void

ifcont:                                           ; preds = %entry
  %4 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %4, 12
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i32, ptr %field_ptr2, align 4
  %sext4 = sext i32 %field_val3 to i64
  %multmp = mul i64 %sext4, 2
  %int_trunc = trunc i64 %multmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %newCap, align 8
  %5 = load i64, ptr %newCap, align 8
  %6 = load i64, ptr %minCap, align 8
  %cmptmp5 = icmp slt i64 %5, %6
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  %7 = load i64, ptr %minCap, align 8
  store i64 %7, ptr %newCap, align 8
  br label %ifcont9

ifcont9:                                          ; preds = %then8, %ifcont
  %8 = load i64, ptr %newCap, align 8
  %alloc_persistent_nz_tmp = call i64 @nova_bytes_alloc_persistent_nz(i64 %8)
  store i64 %alloc_persistent_nz_tmp, ptr %newBuf, align 8
  %9 = load i64, ptr %newBuf, align 8
  %10 = load i64, ptr %self, align 8
  %field_addr10 = add i64 %10, 0
  %field_ptr11 = inttoptr i64 %field_addr10 to ptr
  %field_val12 = load i64, ptr %field_ptr11, align 8
  %11 = load i64, ptr %self, align 8
  %field_addr13 = add i64 %11, 8
  %field_ptr14 = inttoptr i64 %field_addr13 to ptr
  %field_val15 = load i32, ptr %field_ptr14, align 4
  %sext16 = sext i32 %field_val15 to i64
  call void @nova_bytes_copy(i64 %9, i64 %field_val12, i64 %sext16)
  %12 = load i64, ptr %self, align 8
  %field_addr17 = add i64 %12, 0
  %field_ptr18 = inttoptr i64 %field_addr17 to ptr
  %field_val19 = load i64, ptr %field_ptr18, align 8
  %cmptmp20 = icmp ne i64 %field_val19, 0
  %zexttmp21 = zext i1 %cmptmp20 to i64
  %ifcond22 = icmp ne i64 %zexttmp21, 0
  br i1 %ifcond22, label %then23, label %ifcont24

then23:                                           ; preds = %ifcont9
  %13 = load i64, ptr %self, align 8
  %field_addr25 = add i64 %13, 0
  %field_ptr26 = inttoptr i64 %field_addr25 to ptr
  %field_val27 = load i64, ptr %field_ptr26, align 8
  call void @nova_bytes_free(i64 %field_val27)
  br label %ifcont24

ifcont24:                                         ; preds = %then23, %ifcont9
  %14 = load i64, ptr %newBuf, align 8
  %15 = load i64, ptr %self, align 8
  %field_addr28 = add i64 %15, 0
  %field_ptr29 = inttoptr i64 %field_addr28 to ptr
  store i64 %14, ptr %field_ptr29, align 8
  %16 = load i64, ptr %newCap, align 8
  %17 = load i64, ptr %self, align 8
  %field_addr30 = add i64 %17, 12
  %field_ptr31 = inttoptr i64 %field_addr30 to ptr
  %trunc = trunc i64 %16 to i32
  store i32 %trunc, ptr %field_ptr31, align 4
  ret void
}

define void @StringBuilder_delete(i64 %0) {
entry:
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %1 = load i64, ptr %self, align 8
  %field_addr = add i64 %1, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_val = load i64, ptr %field_ptr, align 8
  %cmptmp = icmp ne i64 %field_val, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %2 = load i64, ptr %self, align 8
  %field_addr1 = add i64 %2, 0
  %field_ptr2 = inttoptr i64 %field_addr1 to ptr
  %field_val3 = load i64, ptr %field_ptr2, align 8
  call void @nova_bytes_free(i64 %field_val3)
  %3 = load i64, ptr %self, align 8
  %field_addr4 = add i64 %3, 0
  %field_ptr5 = inttoptr i64 %field_addr4 to ptr
  store i64 0, ptr %field_ptr5, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define i64 @LookupError_message(i64 %0) {
entry:
  %tmp_slot5 = alloca i64, align 8
  store i64 0, ptr %tmp_slot5, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %self = alloca i64, align 8
  store i64 %0, ptr %self, align 8
  %k = alloca i64, align 8
  store i64 0, ptr %k, align 8
  %ms = alloca i64, align 8
  store i64 0, ptr %ms, align 8
  %1 = load i64, ptr %self, align 8
  %tag_ptr = inttoptr i64 %1 to ptr
  %tag_val = load i64, ptr %tag_ptr, align 8
  switch i64 %tag_val, label %switch_default [
    i64 0, label %switch_case
    i64 1, label %switch_case1
  ]

switch_default:                                   ; preds = %entry
  br label %switch_merge

switch_merge:                                     ; preds = %switch_default
  %var_rel_load7 = load i64, ptr %k, align 8
  call void @nova_release(i64 %var_rel_load7, ptr null)
  ret i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [7 x i8] }>, ptr @str_literal.79, i32 0, i32 2) to i64)

switch_case:                                      ; preds = %entry
  %payload_addr = add i64 %1, 8
  %payload_ptr = inttoptr i64 %payload_addr to ptr
  %payload_val = load i64, ptr %payload_ptr, align 8
  call void @nova_retain(i64 %payload_val)
  store i64 %payload_val, ptr %k, align 8
  %2 = load i64, ptr %k, align 8
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [11 x i8] }>, ptr @str_literal.76, i32 0, i32 2) to i64), i64 %2)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %var_rel_load = load i64, ptr %k, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %concat_tmp

switch_case1:                                     ; preds = %entry
  %payload_addr2 = add i64 %1, 8
  %payload_ptr3 = inttoptr i64 %payload_addr2 to ptr
  %payload_val4 = load i64, ptr %payload_ptr3, align 8
  store i64 %payload_val4, ptr %ms, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @StringBuilder_init(i64 %alloc_tmp)
  call void @StringBuilder_append(i64 %alloc_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [16 x i8] }>, ptr @str_literal.77, i32 0, i32 2) to i64))
  %3 = load i64, ptr %ms, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %3)
  call void @StringBuilder_append(i64 %alloc_tmp, i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  call void @StringBuilder_append(i64 %alloc_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.78, i32 0, i32 2) to i64))
  %final_str = call i64 @StringBuilder_toString(i64 %alloc_tmp)
  call void @StringBuilder_delete(i64 %alloc_tmp)
  call void @nova_release(i64 %alloc_tmp, ptr null)
  store i64 %final_str, ptr %tmp_slot5, align 8
  %var_rel_load6 = load i64, ptr %k, align 8
  call void @nova_release(i64 %var_rel_load6, ptr null)
  ret i64 %final_str
}

define void @collections_list_test_list() {
entry:
  %tmp_slot8 = alloca i64, align 8
  store i64 0, ptr %tmp_slot8, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %list = alloca i64, align 8
  store i64 0, ptr %list, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_i32_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %list, align 8
  %0 = load i64, ptr %list, align 8
  %calltmp = call i64 @List_i32_size(i64 %0)
  %cmptmp = icmp ne i64 %calltmp, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [14 x i8] }>, ptr @str_literal.1, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  %1 = load i64, ptr %list, align 8
  call void @List_i32_push(i64 %1, i64 10)
  %2 = load i64, ptr %list, align 8
  call void @List_i32_push(i64 %2, i64 20)
  %3 = load i64, ptr %list, align 8
  call void @List_i32_push(i64 %3, i64 30)
  %4 = load i64, ptr %list, align 8
  %calltmp1 = call i64 @List_i32_size(i64 %4)
  %cmptmp2 = icmp ne i64 %calltmp1, 3
  %zexttmp3 = zext i1 %cmptmp2 to i64
  %ifcond4 = icmp ne i64 %zexttmp3, 0
  br i1 %ifcond4, label %then5, label %ifcont6

then5:                                            ; preds = %ifcont
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [14 x i8] }>, ptr @str_literal.2, i32 0, i32 2))
  br label %ifcont6

ifcont6:                                          ; preds = %then5, %ifcont
  %5 = load i64, ptr %list, align 8
  %calltmp7 = call i64 @List_i32_get(i64 %5, i64 0)
  store i64 %calltmp7, ptr %tmp_slot8, align 8
  %valopt_unbox = call i64 @nova_valopt_unbox(i64 %calltmp7)
  %cmptmp9 = icmp ne i64 %valopt_unbox, 10
  %zexttmp10 = zext i1 %cmptmp9 to i64
  %ifcond11 = icmp ne i64 %zexttmp10, 0
  %tmp_rel = load i64, ptr %tmp_slot8, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot8, align 8
  br i1 %ifcond11, label %then12, label %ifcont13

then12:                                           ; preds = %ifcont6
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [13 x i8] }>, ptr @str_literal.3, i32 0, i32 2))
  br label %ifcont13

ifcont13:                                         ; preds = %then12, %ifcont6
  %var_rel_load = load i64, ptr %list, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_i32)
  ret void
}

define i64 @string_len(i64 %0) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  ret i64 %len_val_ext
}

define i64 @string_allocString(i64 %0) {
entry:
  %len = alloca i64, align 8
  store i64 %0, ptr %len, align 8
  %1 = load i64, ptr %len, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %1)
  ret i64 %alloc_tmp
}

define i64 @string_concat(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %len_a = alloca i64, align 8
  store i64 0, ptr %len_a, align 8
  %len_b = alloca i64, align 8
  store i64 0, ptr %len_b, align 8
  %total_len = alloca i64, align 8
  store i64 0, ptr %total_len, align 8
  %ptr = alloca i64, align 8
  store i64 0, ptr %ptr, align 8
  %2 = load i64, ptr %a, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len_a, align 8
  %3 = load i64, ptr %b, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %len_b, align 8
  %4 = load i64, ptr %len_a, align 8
  %5 = load i64, ptr %len_b, align 8
  %addtmp = add i64 %4, %5
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %total_len, align 8
  %6 = load i64, ptr %total_len, align 8
  %cmptmp = icmp eq i64 %6, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %var_rel_load = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2) to i64)

ifcont:                                           ; preds = %entry
  %7 = load i64, ptr %total_len, align 8
  %calltmp = call i64 @string_allocString(i64 %7)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %ptr, align 8
  %8 = load i64, ptr %len_a, align 8
  %cmptmp5 = icmp sgt i64 %8, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  %9 = load i64, ptr %ptr, align 8
  %10 = load i64, ptr %a, align 8
  %11 = load i64, ptr %len_a, align 8
  call void @nova_bytes_copy(i64 %9, i64 %10, i64 %11)
  br label %ifcont9

ifcont9:                                          ; preds = %then8, %ifcont
  %12 = load i64, ptr %len_b, align 8
  %cmptmp10 = icmp sgt i64 %12, 0
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %ifcond12 = icmp ne i64 %zexttmp11, 0
  br i1 %ifcond12, label %then13, label %ifcont14

then13:                                           ; preds = %ifcont9
  %13 = load i64, ptr %ptr, align 8
  %14 = load i64, ptr %len_a, align 8
  %addtmp15 = add i64 %13, %14
  %15 = load i64, ptr %b, align 8
  %16 = load i64, ptr %len_b, align 8
  call void @nova_bytes_copy(i64 %addtmp15, i64 %15, i64 %16)
  br label %ifcont14

ifcont14:                                         ; preds = %then13, %ifcont9
  %17 = load i64, ptr %ptr, align 8
  call void @nova_retain(i64 %17)
  %var_rel_load16 = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load16, ptr null)
  ret i64 %17
}

define i64 @string_split(i64 %0, i64 %1) {
entry:
  %tmp_slot24 = alloca i64, align 8
  store i64 0, ptr %tmp_slot24, align 8
  %tmp_slot21 = alloca i64, align 8
  store i64 0, ptr %tmp_slot21, align 8
  %tmp_slot7 = alloca i64, align 8
  store i64 0, ptr %tmp_slot7, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %sep = alloca i64, align 8
  store i64 %1, ptr %sep, align 8
  %result = alloca i64, align 8
  store i64 0, ptr %result, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %sep_len = alloca i64, align 8
  store i64 0, ptr %sep_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %char_len = alloca i64, align 8
  store i64 0, ptr %char_len, align 8
  %char_ptr = alloca i64, align 8
  store i64 0, ptr %char_ptr, align 8
  %start = alloca i64, align 8
  store i64 0, ptr %start, align 8
  %pos = alloca i64, align 8
  store i64 0, ptr %pos, align 8
  %remaining = alloca i64, align 8
  store i64 0, ptr %remaining, align 8
  %part = alloca i64, align 8
  store i64 0, ptr %part, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @List_string_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %result, align 8
  %2 = load i64, ptr %s, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %3 = load i64, ptr %sep, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %sep_len, align 8
  %4 = load i64, ptr %sep_len, align 8
  %cmptmp = icmp eq i64 %4, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  store i64 0, ptr %i, align 8
  br label %while_cond

ifcont:                                           ; preds = %entry
  store i64 0, ptr %start, align 8
  br label %while_cond11

while_cond:                                       ; preds = %while_body, %then
  %5 = load i64, ptr %i, align 8
  %6 = load i64, ptr %s_len, align 8
  %cmptmp5 = icmp slt i64 %5, %6
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %whilecond = icmp ne i64 %zexttmp6, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  store i64 1, ptr %char_len, align 8
  %calltmp = call i64 @string_allocString(i64 1)
  store i64 %calltmp, ptr %tmp_slot7, align 8
  store i64 %calltmp, ptr %char_ptr, align 8
  %7 = load i64, ptr %char_ptr, align 8
  %8 = load i64, ptr %s, align 8
  %9 = load i64, ptr %i, align 8
  %index_addr = add i64 %8, %9
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %addr = add i64 %7, 0
  %write_ptr = inttoptr i64 %addr to ptr
  %byte_val8 = trunc i64 %byte_val_ext to i8
  store i8 %byte_val8, ptr %write_ptr, align 1
  %10 = load i64, ptr %result, align 8
  %11 = load i64, ptr %char_ptr, align 8
  call void @List_string_push(i64 %10, i64 %11)
  %12 = load i64, ptr %i, align 8
  %addtmp = add i64 %12, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  %blk_rel_load = load i64, ptr %char_ptr, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %char_ptr, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %13 = load i64, ptr %result, align 8
  call void @nova_retain(i64 %13)
  %var_rel_load = load i64, ptr %result, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_List_string)
  %var_rel_load9 = load i64, ptr %remaining, align 8
  call void @nova_release(i64 %var_rel_load9, ptr null)
  %var_rel_load10 = load i64, ptr %part, align 8
  call void @nova_release(i64 %var_rel_load10, ptr null)
  ret i64 %13

while_cond11:                                     ; preds = %ifcont19, %ifcont
  br i1 true, label %while_body12, label %while_exit13

while_body12:                                     ; preds = %while_cond11
  %14 = load i64, ptr %s, align 8
  %15 = load i64, ptr %sep, align 8
  %16 = load i64, ptr %start, align 8
  %calltmp14 = call i64 @string_indexOfFrom(i64 %14, i64 %15, i64 %16)
  store i64 %calltmp14, ptr %pos, align 8
  %17 = load i64, ptr %pos, align 8
  %cmptmp15 = icmp eq i64 %17, -1
  %zexttmp16 = zext i1 %cmptmp15 to i64
  %ifcond17 = icmp ne i64 %zexttmp16, 0
  br i1 %ifcond17, label %then18, label %ifcont19

while_exit13:                                     ; preds = %then18, %while_cond11
  %18 = load i64, ptr %result, align 8
  call void @nova_retain(i64 %18)
  %var_rel_load29 = load i64, ptr %result, align 8
  call void @nova_release(i64 %var_rel_load29, ptr @__destruct_List_string)
  ret i64 %18

then18:                                           ; preds = %while_body12
  %19 = load i64, ptr %s, align 8
  %20 = load i64, ptr %start, align 8
  %21 = load i64, ptr %s_len, align 8
  %calltmp20 = call i64 @string_slice(i64 %19, i64 %20, i64 %21)
  store i64 %calltmp20, ptr %tmp_slot21, align 8
  store i64 %calltmp20, ptr %remaining, align 8
  %22 = load i64, ptr %result, align 8
  %23 = load i64, ptr %remaining, align 8
  call void @List_string_push(i64 %22, i64 %23)
  %blk_rel_load22 = load i64, ptr %remaining, align 8
  call void @nova_release(i64 %blk_rel_load22, ptr null)
  store i64 0, ptr %remaining, align 8
  br label %while_exit13

ifcont19:                                         ; preds = %while_body12
  %24 = load i64, ptr %s, align 8
  %25 = load i64, ptr %start, align 8
  %26 = load i64, ptr %pos, align 8
  %calltmp23 = call i64 @string_slice(i64 %24, i64 %25, i64 %26)
  store i64 %calltmp23, ptr %tmp_slot24, align 8
  store i64 %calltmp23, ptr %part, align 8
  %27 = load i64, ptr %result, align 8
  %28 = load i64, ptr %part, align 8
  call void @List_string_push(i64 %27, i64 %28)
  %29 = load i64, ptr %pos, align 8
  %30 = load i64, ptr %sep_len, align 8
  %addtmp25 = add i64 %29, %30
  %int_trunc26 = trunc i64 %addtmp25 to i32
  %int_sext27 = sext i32 %int_trunc26 to i64
  store i64 %int_sext27, ptr %start, align 8
  %blk_rel_load28 = load i64, ptr %part, align 8
  call void @nova_release(i64 %blk_rel_load28, ptr null)
  store i64 0, ptr %part, align 8
  br label %while_cond11
}

define i64 @string_join(i64 %0, i64 %1) {
entry:
  %tmp_slot35 = alloca i64, align 8
  store i64 0, ptr %tmp_slot35, align 8
  %tmp_slot27 = alloca i64, align 8
  store i64 0, ptr %tmp_slot27, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %list = alloca i64, align 8
  store i64 %0, ptr %list, align 8
  %sep = alloca i64, align 8
  store i64 %1, ptr %sep, align 8
  %sep_len = alloca i64, align 8
  store i64 0, ptr %sep_len, align 8
  %list_len = alloca i64, align 8
  store i64 0, ptr %list_len, align 8
  %total_len = alloca i64, align 8
  store i64 0, ptr %total_len, align 8
  %idx = alloca i64, align 8
  store i64 0, ptr %idx, align 8
  %s = alloca i64, align 8
  store i64 0, ptr %s, align 8
  %ptr = alloca i64, align 8
  store i64 0, ptr %ptr, align 8
  %offset = alloca i64, align 8
  store i64 0, ptr %offset, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %"s$1" = alloca i64, align 8
  store i64 0, ptr %"s$1", align 8
  %len_s = alloca i64, align 8
  store i64 0, ptr %len_s, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %k = alloca i64, align 8
  store i64 0, ptr %k, align 8
  %2 = load i64, ptr %list, align 8
  %calltmp = call i64 @List_string_size(i64 %2)
  %cmptmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %var_rel_load = load i64, ptr %s, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  %var_rel_load1 = load i64, ptr %"s$1", align 8
  call void @nova_release(i64 %var_rel_load1, ptr null)
  %var_rel_load2 = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load2, ptr null)
  ret i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2) to i64)

ifcont:                                           ; preds = %entry
  %3 = load i64, ptr %sep, align 8
  %len_addr = sub i64 %3, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %sep_len, align 8
  %4 = load i64, ptr %list, align 8
  %calltmp3 = call i64 @List_string_size(i64 %4)
  store i64 %calltmp3, ptr %list_len, align 8
  store i64 0, ptr %total_len, align 8
  store i64 0, ptr %idx, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont11, %ifcont
  %5 = load i64, ptr %idx, align 8
  %6 = load i64, ptr %list_len, align 8
  %cmptmp4 = icmp slt i64 %5, %6
  %zexttmp5 = zext i1 %cmptmp4 to i64
  %whilecond = icmp ne i64 %zexttmp5, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %7 = load i64, ptr %list, align 8
  %8 = load i64, ptr %idx, align 8
  %calltmp6 = call i64 @List_string_get(i64 %7, i64 %8)
  store i64 %calltmp6, ptr %tmp_slot, align 8
  store i64 %calltmp6, ptr %s, align 8
  %9 = load i64, ptr %s, align 8
  %cmptmp7 = icmp ne i64 %9, 0
  %zexttmp8 = zext i1 %cmptmp7 to i64
  %ifcond9 = icmp ne i64 %zexttmp8, 0
  br i1 %ifcond9, label %then10, label %ifcont11

while_exit:                                       ; preds = %while_cond
  %10 = load i64, ptr %total_len, align 8
  %11 = load i64, ptr %sep_len, align 8
  %12 = load i64, ptr %list_len, align 8
  %subtmp = sub i64 %12, 1
  %int_trunc19 = trunc i64 %subtmp to i32
  %int_sext20 = sext i32 %int_trunc19 to i64
  %multmp = mul i64 %11, %int_sext20
  %int_trunc21 = trunc i64 %multmp to i32
  %int_sext22 = sext i32 %int_trunc21 to i64
  %addtmp23 = add i64 %10, %int_sext22
  %int_trunc24 = trunc i64 %addtmp23 to i32
  %int_sext25 = sext i32 %int_trunc24 to i64
  store i64 %int_sext25, ptr %total_len, align 8
  %13 = load i64, ptr %total_len, align 8
  %calltmp26 = call i64 @string_allocString(i64 %13)
  store i64 %calltmp26, ptr %tmp_slot27, align 8
  store i64 %calltmp26, ptr %ptr, align 8
  store i64 0, ptr %offset, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond28

then10:                                           ; preds = %while_body
  %14 = load i64, ptr %total_len, align 8
  %15 = load i64, ptr %s, align 8
  %len_addr12 = sub i64 %15, 4
  %len_ptr13 = inttoptr i64 %len_addr12 to ptr
  %len_val14 = load i32, ptr %len_ptr13, align 4
  %len_val_ext15 = zext i32 %len_val14 to i64
  %addtmp = add i64 %14, %len_val_ext15
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %total_len, align 8
  br label %ifcont11

ifcont11:                                         ; preds = %then10, %while_body
  %16 = load i64, ptr %idx, align 8
  %addtmp16 = add i64 %16, 1
  %int_trunc17 = trunc i64 %addtmp16 to i32
  %int_sext18 = sext i32 %int_trunc17 to i64
  store i64 %int_sext18, ptr %idx, align 8
  %blk_rel_load = load i64, ptr %s, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %s, align 8
  br label %while_cond

while_cond28:                                     ; preds = %ifcont68, %while_exit
  %17 = load i64, ptr %i, align 8
  %18 = load i64, ptr %list_len, align 8
  %cmptmp31 = icmp slt i64 %17, %18
  %zexttmp32 = zext i1 %cmptmp31 to i64
  %whilecond33 = icmp ne i64 %zexttmp32, 0
  br i1 %whilecond33, label %while_body29, label %while_exit30

while_body29:                                     ; preds = %while_cond28
  %19 = load i64, ptr %list, align 8
  %20 = load i64, ptr %i, align 8
  %calltmp34 = call i64 @List_string_get(i64 %19, i64 %20)
  store i64 %calltmp34, ptr %tmp_slot35, align 8
  store i64 %calltmp34, ptr %"s$1", align 8
  %21 = load i64, ptr %"s$1", align 8
  %cmptmp36 = icmp ne i64 %21, 0
  %zexttmp37 = zext i1 %cmptmp36 to i64
  %ifcond38 = icmp ne i64 %zexttmp37, 0
  br i1 %ifcond38, label %then39, label %ifcont40

while_exit30:                                     ; preds = %while_cond28
  %22 = load i64, ptr %ptr, align 8
  call void @nova_retain(i64 %22)
  %var_rel_load95 = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load95, ptr null)
  ret i64 %22

then39:                                           ; preds = %while_body29
  %23 = load i64, ptr %"s$1", align 8
  %len_addr41 = sub i64 %23, 4
  %len_ptr42 = inttoptr i64 %len_addr41 to ptr
  %len_val43 = load i32, ptr %len_ptr42, align 4
  %len_val_ext44 = zext i32 %len_val43 to i64
  store i64 %len_val_ext44, ptr %len_s, align 8
  store i64 0, ptr %j, align 8
  br label %while_cond45

ifcont40:                                         ; preds = %while_exit47, %while_body29
  %24 = load i64, ptr %i, align 8
  %25 = load i64, ptr %list_len, align 8
  %subtmp61 = sub i64 %25, 1
  %int_trunc62 = trunc i64 %subtmp61 to i32
  %int_sext63 = sext i32 %int_trunc62 to i64
  %cmptmp64 = icmp slt i64 %24, %int_sext63
  %zexttmp65 = zext i1 %cmptmp64 to i64
  %ifcond66 = icmp ne i64 %zexttmp65, 0
  br i1 %ifcond66, label %then67, label %ifcont68

while_cond45:                                     ; preds = %while_body46, %then39
  %26 = load i64, ptr %j, align 8
  %27 = load i64, ptr %len_s, align 8
  %cmptmp48 = icmp slt i64 %26, %27
  %zexttmp49 = zext i1 %cmptmp48 to i64
  %whilecond50 = icmp ne i64 %zexttmp49, 0
  br i1 %whilecond50, label %while_body46, label %while_exit47

while_body46:                                     ; preds = %while_cond45
  %28 = load i64, ptr %ptr, align 8
  %29 = load i64, ptr %offset, align 8
  %30 = load i64, ptr %j, align 8
  %addtmp51 = add i64 %29, %30
  %int_trunc52 = trunc i64 %addtmp51 to i32
  %int_sext53 = sext i32 %int_trunc52 to i64
  %31 = load i64, ptr %"s$1", align 8
  %32 = load i64, ptr %j, align 8
  %index_addr = add i64 %31, %32
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %addr = add i64 %28, %int_sext53
  %write_ptr = inttoptr i64 %addr to ptr
  %byte_val54 = trunc i64 %byte_val_ext to i8
  store i8 %byte_val54, ptr %write_ptr, align 1
  %33 = load i64, ptr %j, align 8
  %addtmp55 = add i64 %33, 1
  %int_trunc56 = trunc i64 %addtmp55 to i32
  %int_sext57 = sext i32 %int_trunc56 to i64
  store i64 %int_sext57, ptr %j, align 8
  br label %while_cond45

while_exit47:                                     ; preds = %while_cond45
  %34 = load i64, ptr %offset, align 8
  %35 = load i64, ptr %len_s, align 8
  %addtmp58 = add i64 %34, %35
  %int_trunc59 = trunc i64 %addtmp58 to i32
  %int_sext60 = sext i32 %int_trunc59 to i64
  store i64 %int_sext60, ptr %offset, align 8
  br label %ifcont40

then67:                                           ; preds = %ifcont40
  store i64 0, ptr %k, align 8
  br label %while_cond69

ifcont68:                                         ; preds = %while_exit71, %ifcont40
  %36 = load i64, ptr %i, align 8
  %addtmp91 = add i64 %36, 1
  %int_trunc92 = trunc i64 %addtmp91 to i32
  %int_sext93 = sext i32 %int_trunc92 to i64
  store i64 %int_sext93, ptr %i, align 8
  %blk_rel_load94 = load i64, ptr %"s$1", align 8
  call void @nova_release(i64 %blk_rel_load94, ptr null)
  store i64 0, ptr %"s$1", align 8
  br label %while_cond28

while_cond69:                                     ; preds = %while_body70, %then67
  %37 = load i64, ptr %k, align 8
  %38 = load i64, ptr %sep_len, align 8
  %cmptmp72 = icmp slt i64 %37, %38
  %zexttmp73 = zext i1 %cmptmp72 to i64
  %whilecond74 = icmp ne i64 %zexttmp73, 0
  br i1 %whilecond74, label %while_body70, label %while_exit71

while_body70:                                     ; preds = %while_cond69
  %39 = load i64, ptr %ptr, align 8
  %40 = load i64, ptr %offset, align 8
  %41 = load i64, ptr %k, align 8
  %addtmp75 = add i64 %40, %41
  %int_trunc76 = trunc i64 %addtmp75 to i32
  %int_sext77 = sext i32 %int_trunc76 to i64
  %42 = load i64, ptr %sep, align 8
  %43 = load i64, ptr %k, align 8
  %index_addr78 = add i64 %42, %43
  %index_ptr79 = inttoptr i64 %index_addr78 to ptr
  %byte_val80 = load i8, ptr %index_ptr79, align 1
  %byte_val_ext81 = zext i8 %byte_val80 to i64
  %addr82 = add i64 %39, %int_sext77
  %write_ptr83 = inttoptr i64 %addr82 to ptr
  %byte_val84 = trunc i64 %byte_val_ext81 to i8
  store i8 %byte_val84, ptr %write_ptr83, align 1
  %44 = load i64, ptr %k, align 8
  %addtmp85 = add i64 %44, 1
  %int_trunc86 = trunc i64 %addtmp85 to i32
  %int_sext87 = sext i32 %int_trunc86 to i64
  store i64 %int_sext87, ptr %k, align 8
  br label %while_cond69

while_exit71:                                     ; preds = %while_cond69
  %45 = load i64, ptr %offset, align 8
  %46 = load i64, ptr %sep_len, align 8
  %addtmp88 = add i64 %45, %46
  %int_trunc89 = trunc i64 %addtmp88 to i32
  %int_sext90 = sext i32 %int_trunc89 to i64
  store i64 %int_sext90, ptr %offset, align 8
  br label %ifcont68
}

define i64 @string_slice(i64 %0, i64 %1, i64 %2) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %start = alloca i64, align 8
  store i64 %1, ptr %start, align 8
  %end = alloca i64, align 8
  store i64 %2, ptr %end, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %start_clamped = alloca i64, align 8
  store i64 0, ptr %start_clamped, align 8
  %end_clamped = alloca i64, align 8
  store i64 0, ptr %end_clamped, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %ptr = alloca i64, align 8
  store i64 0, ptr %ptr, align 8
  %3 = load i64, ptr %s, align 8
  %len_addr = sub i64 %3, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %4 = load i64, ptr %start, align 8
  %cmptmp = icmp slt i64 %4, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  br label %ifcont

else:                                             ; preds = %entry
  %5 = load i64, ptr %start, align 8
  %6 = load i64, ptr %s_len, align 8
  %cmptmp1 = icmp sgt i64 %5, %6
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ifcond3 = icmp ne i64 %zexttmp2, 0
  br i1 %ifcond3, label %then4, label %else5

ifcont:                                           ; preds = %ifcont6, %then
  %ifphi7 = phi i64 [ 0, %then ], [ %ifphi, %ifcont6 ]
  store i64 %ifphi7, ptr %start_clamped, align 8
  %7 = load i64, ptr %end, align 8
  %8 = load i64, ptr %start_clamped, align 8
  %cmptmp8 = icmp slt i64 %7, %8
  %zexttmp9 = zext i1 %cmptmp8 to i64
  %ifcond10 = icmp ne i64 %zexttmp9, 0
  br i1 %ifcond10, label %then11, label %else12

then4:                                            ; preds = %else
  %9 = load i64, ptr %s_len, align 8
  br label %ifcont6

else5:                                            ; preds = %else
  %10 = load i64, ptr %start, align 8
  br label %ifcont6

ifcont6:                                          ; preds = %else5, %then4
  %ifphi = phi i64 [ %9, %then4 ], [ %10, %else5 ]
  br label %ifcont

then11:                                           ; preds = %ifcont
  %11 = load i64, ptr %start_clamped, align 8
  br label %ifcont13

else12:                                           ; preds = %ifcont
  %12 = load i64, ptr %end, align 8
  %13 = load i64, ptr %s_len, align 8
  %cmptmp14 = icmp sgt i64 %12, %13
  %zexttmp15 = zext i1 %cmptmp14 to i64
  %ifcond16 = icmp ne i64 %zexttmp15, 0
  br i1 %ifcond16, label %then17, label %else18

ifcont13:                                         ; preds = %ifcont19, %then11
  %ifphi21 = phi i64 [ %11, %then11 ], [ %ifphi20, %ifcont19 ]
  store i64 %ifphi21, ptr %end_clamped, align 8
  %14 = load i64, ptr %end_clamped, align 8
  %15 = load i64, ptr %start_clamped, align 8
  %subtmp = sub i64 %14, %15
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %len, align 8
  %16 = load i64, ptr %len, align 8
  %cmptmp22 = icmp sle i64 %16, 0
  %zexttmp23 = zext i1 %cmptmp22 to i64
  %ifcond24 = icmp ne i64 %zexttmp23, 0
  br i1 %ifcond24, label %then25, label %ifcont26

then17:                                           ; preds = %else12
  %17 = load i64, ptr %s_len, align 8
  br label %ifcont19

else18:                                           ; preds = %else12
  %18 = load i64, ptr %end, align 8
  br label %ifcont19

ifcont19:                                         ; preds = %else18, %then17
  %ifphi20 = phi i64 [ %17, %then17 ], [ %18, %else18 ]
  br label %ifcont13

then25:                                           ; preds = %ifcont13
  %var_rel_load = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2) to i64)

ifcont26:                                         ; preds = %ifcont13
  %19 = load i64, ptr %len, align 8
  %calltmp = call i64 @string_allocString(i64 %19)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %ptr, align 8
  %20 = load i64, ptr %ptr, align 8
  %21 = load i64, ptr %s, align 8
  %22 = load i64, ptr %start_clamped, align 8
  %addtmp = add i64 %21, %22
  %23 = load i64, ptr %len, align 8
  call void @nova_bytes_copy(i64 %20, i64 %addtmp, i64 %23)
  %24 = load i64, ptr %ptr, align 8
  call void @nova_retain(i64 %24)
  %var_rel_load27 = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load27, ptr null)
  ret i64 %24
}

define i64 @string_trim(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %start = alloca i64, align 8
  store i64 0, ptr %start, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %end = alloca i64, align 8
  store i64 0, ptr %end, align 8
  %"c$1" = alloca i64, align 8
  store i64 0, ptr %"c$1", align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  store i64 0, ptr %start, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %2 = load i64, ptr %start, align 8
  %3 = load i64, ptr %len, align 8
  %cmptmp = icmp slt i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %s, align 8
  %5 = load i64, ptr %start, align 8
  %index_addr = add i64 %4, %5
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  store i64 %byte_val_ext, ptr %c, align 8
  %6 = load i64, ptr %c, align 8
  %cmptmp1 = icmp ne i64 %6, 32
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %7 = load i64, ptr %c, align 8
  %cmptmp3 = icmp ne i64 %7, 9
  %zexttmp4 = zext i1 %cmptmp3 to i64
  %andtmp = and i64 %zexttmp2, %zexttmp4
  %8 = load i64, ptr %c, align 8
  %cmptmp5 = icmp ne i64 %8, 10
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %andtmp7 = and i64 %andtmp, %zexttmp6
  %9 = load i64, ptr %c, align 8
  %cmptmp8 = icmp ne i64 %9, 13
  %zexttmp9 = zext i1 %cmptmp8 to i64
  %andtmp10 = and i64 %andtmp7, %zexttmp9
  %ifcond = icmp ne i64 %andtmp10, 0
  br i1 %ifcond, label %then, label %ifcont

while_exit:                                       ; preds = %then, %while_cond
  %10 = load i64, ptr %len, align 8
  store i64 %10, ptr %end, align 8
  br label %while_cond11

then:                                             ; preds = %while_body
  br label %while_exit

ifcont:                                           ; preds = %while_body
  %11 = load i64, ptr %start, align 8
  %addtmp = add i64 %11, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %start, align 8
  br label %while_cond

while_cond11:                                     ; preds = %ifcont36, %while_exit
  %12 = load i64, ptr %end, align 8
  %13 = load i64, ptr %start, align 8
  %cmptmp14 = icmp sgt i64 %12, %13
  %zexttmp15 = zext i1 %cmptmp14 to i64
  %whilecond16 = icmp ne i64 %zexttmp15, 0
  br i1 %whilecond16, label %while_body12, label %while_exit13

while_body12:                                     ; preds = %while_cond11
  %14 = load i64, ptr %s, align 8
  %15 = load i64, ptr %end, align 8
  %subtmp = sub i64 %15, 1
  %int_trunc17 = trunc i64 %subtmp to i32
  %int_sext18 = sext i32 %int_trunc17 to i64
  %index_addr19 = add i64 %14, %int_sext18
  %index_ptr20 = inttoptr i64 %index_addr19 to ptr
  %byte_val21 = load i8, ptr %index_ptr20, align 1
  %byte_val_ext22 = zext i8 %byte_val21 to i64
  store i64 %byte_val_ext22, ptr %"c$1", align 8
  %16 = load i64, ptr %"c$1", align 8
  %cmptmp23 = icmp ne i64 %16, 32
  %zexttmp24 = zext i1 %cmptmp23 to i64
  %17 = load i64, ptr %"c$1", align 8
  %cmptmp25 = icmp ne i64 %17, 9
  %zexttmp26 = zext i1 %cmptmp25 to i64
  %andtmp27 = and i64 %zexttmp24, %zexttmp26
  %18 = load i64, ptr %"c$1", align 8
  %cmptmp28 = icmp ne i64 %18, 10
  %zexttmp29 = zext i1 %cmptmp28 to i64
  %andtmp30 = and i64 %andtmp27, %zexttmp29
  %19 = load i64, ptr %"c$1", align 8
  %cmptmp31 = icmp ne i64 %19, 13
  %zexttmp32 = zext i1 %cmptmp31 to i64
  %andtmp33 = and i64 %andtmp30, %zexttmp32
  %ifcond34 = icmp ne i64 %andtmp33, 0
  br i1 %ifcond34, label %then35, label %ifcont36

while_exit13:                                     ; preds = %then35, %while_cond11
  %20 = load i64, ptr %s, align 8
  %21 = load i64, ptr %start, align 8
  %22 = load i64, ptr %end, align 8
  %calltmp = call i64 @string_slice(i64 %20, i64 %21, i64 %22)
  store i64 %calltmp, ptr %tmp_slot, align 8
  ret i64 %calltmp

then35:                                           ; preds = %while_body12
  br label %while_exit13

ifcont36:                                         ; preds = %while_body12
  %23 = load i64, ptr %end, align 8
  %subtmp37 = sub i64 %23, 1
  %int_trunc38 = trunc i64 %subtmp37 to i32
  %int_sext39 = sext i32 %int_trunc38 to i64
  store i64 %int_sext39, ptr %end, align 8
  br label %while_cond11
}

define i64 @string_replace(i64 %0, i64 %1, i64 %2) {
entry:
  %tmp_slot97 = alloca i64, align 8
  store i64 0, ptr %tmp_slot97, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %old = alloca i64, align 8
  store i64 %1, ptr %old, align 8
  %new = alloca i64, align 8
  store i64 %2, ptr %new, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %old_len = alloca i64, align 8
  store i64 0, ptr %old_len, align 8
  %new_len = alloca i64, align 8
  store i64 0, ptr %new_len, align 8
  %result = alloca i64, align 8
  store i64 0, ptr %result, align 8
  %offset = alloca i64, align 8
  store i64 0, ptr %offset, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %k = alloca i64, align 8
  store i64 0, ptr %k, align 8
  %"k$1" = alloca i64, align 8
  store i64 0, ptr %"k$1", align 8
  %count = alloca i64, align 8
  store i64 0, ptr %count, align 8
  %pos = alloca i64, align 8
  store i64 0, ptr %pos, align 8
  %idx = alloca i64, align 8
  store i64 0, ptr %idx, align 8
  %result_len = alloca i64, align 8
  store i64 0, ptr %result_len, align 8
  %"result$2" = alloca i64, align 8
  store i64 0, ptr %"result$2", align 8
  %"offset$3" = alloca i64, align 8
  store i64 0, ptr %"offset$3", align 8
  %search_start = alloca i64, align 8
  store i64 0, ptr %search_start, align 8
  %"idx$4" = alloca i64, align 8
  store i64 0, ptr %"idx$4", align 8
  %remaining_len = alloca i64, align 8
  store i64 0, ptr %remaining_len, align 8
  %"k$5" = alloca i64, align 8
  store i64 0, ptr %"k$5", align 8
  %before_len = alloca i64, align 8
  store i64 0, ptr %before_len, align 8
  %"k$6" = alloca i64, align 8
  store i64 0, ptr %"k$6", align 8
  %"k$7" = alloca i64, align 8
  store i64 0, ptr %"k$7", align 8
  %3 = load i64, ptr %s, align 8
  %len_addr = sub i64 %3, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %4 = load i64, ptr %old, align 8
  %len_addr1 = sub i64 %4, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %old_len, align 8
  %5 = load i64, ptr %new, align 8
  %len_addr5 = sub i64 %5, 4
  %len_ptr6 = inttoptr i64 %len_addr5 to ptr
  %len_val7 = load i32, ptr %len_ptr6, align 4
  %len_val_ext8 = zext i32 %len_val7 to i64
  store i64 %len_val_ext8, ptr %new_len, align 8
  %6 = load i64, ptr %old_len, align 8
  %cmptmp = icmp eq i64 %6, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %7 = load i64, ptr %s_len, align 8
  %8 = load i64, ptr %new_len, align 8
  %addtmp = add i64 %8, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %multmp = mul i64 %7, %int_sext
  %int_trunc9 = trunc i64 %multmp to i32
  %int_sext10 = sext i32 %int_trunc9 to i64
  %9 = load i64, ptr %new_len, align 8
  %addtmp11 = add i64 %int_sext10, %9
  %int_trunc12 = trunc i64 %addtmp11 to i32
  %int_sext13 = sext i32 %int_trunc12 to i64
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %int_sext13)
  store i64 %alloc_tmp, ptr %result, align 8
  store i64 0, ptr %offset, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

ifcont:                                           ; preds = %entry
  store i64 0, ptr %count, align 8
  store i64 0, ptr %pos, align 8
  br label %while_cond67

while_cond:                                       ; preds = %while_exit18, %then
  %10 = load i64, ptr %i, align 8
  %11 = load i64, ptr %s_len, align 8
  %cmptmp14 = icmp slt i64 %10, %11
  %zexttmp15 = zext i1 %cmptmp14 to i64
  %whilecond = icmp ne i64 %zexttmp15, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  store i64 0, ptr %k, align 8
  br label %while_cond16

while_exit:                                       ; preds = %while_cond
  store i64 0, ptr %"k$1", align 8
  br label %while_cond45

while_cond16:                                     ; preds = %while_body17, %while_body
  %12 = load i64, ptr %k, align 8
  %13 = load i64, ptr %new_len, align 8
  %cmptmp19 = icmp slt i64 %12, %13
  %zexttmp20 = zext i1 %cmptmp19 to i64
  %whilecond21 = icmp ne i64 %zexttmp20, 0
  br i1 %whilecond21, label %while_body17, label %while_exit18

while_body17:                                     ; preds = %while_cond16
  %14 = load i64, ptr %result, align 8
  %15 = load i64, ptr %offset, align 8
  %16 = load i64, ptr %k, align 8
  %addtmp22 = add i64 %15, %16
  %int_trunc23 = trunc i64 %addtmp22 to i32
  %int_sext24 = sext i32 %int_trunc23 to i64
  %17 = load i64, ptr %new, align 8
  %18 = load i64, ptr %k, align 8
  %index_addr = add i64 %17, %18
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %addr = add i64 %14, %int_sext24
  %write_ptr = inttoptr i64 %addr to ptr
  %byte_val25 = trunc i64 %byte_val_ext to i8
  store i8 %byte_val25, ptr %write_ptr, align 1
  %19 = load i64, ptr %k, align 8
  %addtmp26 = add i64 %19, 1
  %int_trunc27 = trunc i64 %addtmp26 to i32
  %int_sext28 = sext i32 %int_trunc27 to i64
  store i64 %int_sext28, ptr %k, align 8
  br label %while_cond16

while_exit18:                                     ; preds = %while_cond16
  %20 = load i64, ptr %offset, align 8
  %21 = load i64, ptr %new_len, align 8
  %addtmp29 = add i64 %20, %21
  %int_trunc30 = trunc i64 %addtmp29 to i32
  %int_sext31 = sext i32 %int_trunc30 to i64
  store i64 %int_sext31, ptr %offset, align 8
  %22 = load i64, ptr %result, align 8
  %23 = load i64, ptr %offset, align 8
  %24 = load i64, ptr %s, align 8
  %25 = load i64, ptr %i, align 8
  %index_addr32 = add i64 %24, %25
  %index_ptr33 = inttoptr i64 %index_addr32 to ptr
  %byte_val34 = load i8, ptr %index_ptr33, align 1
  %byte_val_ext35 = zext i8 %byte_val34 to i64
  %addr36 = add i64 %22, %23
  %write_ptr37 = inttoptr i64 %addr36 to ptr
  %byte_val38 = trunc i64 %byte_val_ext35 to i8
  store i8 %byte_val38, ptr %write_ptr37, align 1
  %26 = load i64, ptr %offset, align 8
  %addtmp39 = add i64 %26, 1
  %int_trunc40 = trunc i64 %addtmp39 to i32
  %int_sext41 = sext i32 %int_trunc40 to i64
  store i64 %int_sext41, ptr %offset, align 8
  %27 = load i64, ptr %i, align 8
  %addtmp42 = add i64 %27, 1
  %int_trunc43 = trunc i64 %addtmp42 to i32
  %int_sext44 = sext i32 %int_trunc43 to i64
  store i64 %int_sext44, ptr %i, align 8
  br label %while_cond

while_cond45:                                     ; preds = %while_body46, %while_exit
  %28 = load i64, ptr %"k$1", align 8
  %29 = load i64, ptr %new_len, align 8
  %cmptmp48 = icmp slt i64 %28, %29
  %zexttmp49 = zext i1 %cmptmp48 to i64
  %whilecond50 = icmp ne i64 %zexttmp49, 0
  br i1 %whilecond50, label %while_body46, label %while_exit47

while_body46:                                     ; preds = %while_cond45
  %30 = load i64, ptr %result, align 8
  %31 = load i64, ptr %offset, align 8
  %32 = load i64, ptr %"k$1", align 8
  %addtmp51 = add i64 %31, %32
  %int_trunc52 = trunc i64 %addtmp51 to i32
  %int_sext53 = sext i32 %int_trunc52 to i64
  %33 = load i64, ptr %new, align 8
  %34 = load i64, ptr %"k$1", align 8
  %index_addr54 = add i64 %33, %34
  %index_ptr55 = inttoptr i64 %index_addr54 to ptr
  %byte_val56 = load i8, ptr %index_ptr55, align 1
  %byte_val_ext57 = zext i8 %byte_val56 to i64
  %addr58 = add i64 %30, %int_sext53
  %write_ptr59 = inttoptr i64 %addr58 to ptr
  %byte_val60 = trunc i64 %byte_val_ext57 to i8
  store i8 %byte_val60, ptr %write_ptr59, align 1
  %35 = load i64, ptr %"k$1", align 8
  %addtmp61 = add i64 %35, 1
  %int_trunc62 = trunc i64 %addtmp61 to i32
  %int_sext63 = sext i32 %int_trunc62 to i64
  store i64 %int_sext63, ptr %"k$1", align 8
  br label %while_cond45

while_exit47:                                     ; preds = %while_cond45
  %36 = load i64, ptr %offset, align 8
  %37 = load i64, ptr %new_len, align 8
  %addtmp64 = add i64 %36, %37
  %int_trunc65 = trunc i64 %addtmp64 to i32
  %int_sext66 = sext i32 %int_trunc65 to i64
  store i64 %int_sext66, ptr %offset, align 8
  %38 = load i64, ptr %result, align 8
  %39 = load i64, ptr %offset, align 8
  %calltmp = call i64 @string_slice(i64 %38, i64 0, i64 %39)
  store i64 %calltmp, ptr %tmp_slot, align 8
  %var_rel_load = load i64, ptr %"result$2", align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %calltmp

while_cond67:                                     ; preds = %ifcont75, %ifcont
  br i1 true, label %while_body68, label %while_exit69

while_body68:                                     ; preds = %while_cond67
  %40 = load i64, ptr %s, align 8
  %41 = load i64, ptr %old, align 8
  %42 = load i64, ptr %pos, align 8
  %calltmp70 = call i64 @string_indexOfFrom(i64 %40, i64 %41, i64 %42)
  store i64 %calltmp70, ptr %idx, align 8
  %43 = load i64, ptr %idx, align 8
  %cmptmp71 = icmp eq i64 %43, -1
  %zexttmp72 = zext i1 %cmptmp71 to i64
  %ifcond73 = icmp ne i64 %zexttmp72, 0
  br i1 %ifcond73, label %then74, label %ifcont75

while_exit69:                                     ; preds = %then74, %while_cond67
  %44 = load i64, ptr %count, align 8
  %cmptmp82 = icmp eq i64 %44, 0
  %zexttmp83 = zext i1 %cmptmp82 to i64
  %ifcond84 = icmp ne i64 %zexttmp83, 0
  br i1 %ifcond84, label %then85, label %ifcont86

then74:                                           ; preds = %while_body68
  br label %while_exit69

ifcont75:                                         ; preds = %while_body68
  %45 = load i64, ptr %count, align 8
  %addtmp76 = add i64 %45, 1
  %int_trunc77 = trunc i64 %addtmp76 to i32
  %int_sext78 = sext i32 %int_trunc77 to i64
  store i64 %int_sext78, ptr %count, align 8
  %46 = load i64, ptr %idx, align 8
  %47 = load i64, ptr %old_len, align 8
  %addtmp79 = add i64 %46, %47
  %int_trunc80 = trunc i64 %addtmp79 to i32
  %int_sext81 = sext i32 %int_trunc80 to i64
  store i64 %int_sext81, ptr %pos, align 8
  br label %while_cond67

then85:                                           ; preds = %while_exit69
  %48 = load i64, ptr %s, align 8
  call void @nova_retain(i64 %48)
  %var_rel_load87 = load i64, ptr %"result$2", align 8
  call void @nova_release(i64 %var_rel_load87, ptr null)
  ret i64 %48

ifcont86:                                         ; preds = %while_exit69
  %49 = load i64, ptr %s_len, align 8
  %50 = load i64, ptr %count, align 8
  %51 = load i64, ptr %new_len, align 8
  %52 = load i64, ptr %old_len, align 8
  %subtmp = sub i64 %51, %52
  %int_trunc88 = trunc i64 %subtmp to i32
  %int_sext89 = sext i32 %int_trunc88 to i64
  %multmp90 = mul i64 %50, %int_sext89
  %int_trunc91 = trunc i64 %multmp90 to i32
  %int_sext92 = sext i32 %int_trunc91 to i64
  %addtmp93 = add i64 %49, %int_sext92
  %int_trunc94 = trunc i64 %addtmp93 to i32
  %int_sext95 = sext i32 %int_trunc94 to i64
  store i64 %int_sext95, ptr %result_len, align 8
  %53 = load i64, ptr %result_len, align 8
  %calltmp96 = call i64 @string_allocString(i64 %53)
  store i64 %calltmp96, ptr %tmp_slot97, align 8
  store i64 %calltmp96, ptr %"result$2", align 8
  store i64 0, ptr %"offset$3", align 8
  store i64 0, ptr %search_start, align 8
  br label %while_cond98

while_cond98:                                     ; preds = %while_exit162, %ifcont86
  br i1 true, label %while_body99, label %while_exit100

while_body99:                                     ; preds = %while_cond98
  %54 = load i64, ptr %s, align 8
  %55 = load i64, ptr %old, align 8
  %56 = load i64, ptr %search_start, align 8
  %calltmp101 = call i64 @string_indexOfFrom(i64 %54, i64 %55, i64 %56)
  store i64 %calltmp101, ptr %"idx$4", align 8
  %57 = load i64, ptr %"idx$4", align 8
  %cmptmp102 = icmp eq i64 %57, -1
  %zexttmp103 = zext i1 %cmptmp102 to i64
  %ifcond104 = icmp ne i64 %zexttmp103, 0
  br i1 %ifcond104, label %then105, label %ifcont106

while_exit100:                                    ; preds = %while_exit112, %while_cond98
  %58 = load i64, ptr %"result$2", align 8
  call void @nova_retain(i64 %58)
  %var_rel_load185 = load i64, ptr %"result$2", align 8
  call void @nova_release(i64 %var_rel_load185, ptr null)
  ret i64 %58

then105:                                          ; preds = %while_body99
  %59 = load i64, ptr %s_len, align 8
  %60 = load i64, ptr %search_start, align 8
  %subtmp107 = sub i64 %59, %60
  %int_trunc108 = trunc i64 %subtmp107 to i32
  %int_sext109 = sext i32 %int_trunc108 to i64
  store i64 %int_sext109, ptr %remaining_len, align 8
  store i64 0, ptr %"k$5", align 8
  br label %while_cond110

ifcont106:                                        ; preds = %while_body99
  %61 = load i64, ptr %"idx$4", align 8
  %62 = load i64, ptr %search_start, align 8
  %subtmp132 = sub i64 %61, %62
  %int_trunc133 = trunc i64 %subtmp132 to i32
  %int_sext134 = sext i32 %int_trunc133 to i64
  store i64 %int_sext134, ptr %before_len, align 8
  store i64 0, ptr %"k$6", align 8
  br label %while_cond135

while_cond110:                                    ; preds = %while_body111, %then105
  %63 = load i64, ptr %"k$5", align 8
  %64 = load i64, ptr %remaining_len, align 8
  %cmptmp113 = icmp slt i64 %63, %64
  %zexttmp114 = zext i1 %cmptmp113 to i64
  %whilecond115 = icmp ne i64 %zexttmp114, 0
  br i1 %whilecond115, label %while_body111, label %while_exit112

while_body111:                                    ; preds = %while_cond110
  %65 = load i64, ptr %"result$2", align 8
  %66 = load i64, ptr %"offset$3", align 8
  %67 = load i64, ptr %"k$5", align 8
  %addtmp116 = add i64 %66, %67
  %int_trunc117 = trunc i64 %addtmp116 to i32
  %int_sext118 = sext i32 %int_trunc117 to i64
  %68 = load i64, ptr %s, align 8
  %69 = load i64, ptr %search_start, align 8
  %70 = load i64, ptr %"k$5", align 8
  %addtmp119 = add i64 %69, %70
  %int_trunc120 = trunc i64 %addtmp119 to i32
  %int_sext121 = sext i32 %int_trunc120 to i64
  %index_addr122 = add i64 %68, %int_sext121
  %index_ptr123 = inttoptr i64 %index_addr122 to ptr
  %byte_val124 = load i8, ptr %index_ptr123, align 1
  %byte_val_ext125 = zext i8 %byte_val124 to i64
  %addr126 = add i64 %65, %int_sext118
  %write_ptr127 = inttoptr i64 %addr126 to ptr
  %byte_val128 = trunc i64 %byte_val_ext125 to i8
  store i8 %byte_val128, ptr %write_ptr127, align 1
  %71 = load i64, ptr %"k$5", align 8
  %addtmp129 = add i64 %71, 1
  %int_trunc130 = trunc i64 %addtmp129 to i32
  %int_sext131 = sext i32 %int_trunc130 to i64
  store i64 %int_sext131, ptr %"k$5", align 8
  br label %while_cond110

while_exit112:                                    ; preds = %while_cond110
  br label %while_exit100

while_cond135:                                    ; preds = %while_body136, %ifcont106
  %72 = load i64, ptr %"k$6", align 8
  %73 = load i64, ptr %before_len, align 8
  %cmptmp138 = icmp slt i64 %72, %73
  %zexttmp139 = zext i1 %cmptmp138 to i64
  %whilecond140 = icmp ne i64 %zexttmp139, 0
  br i1 %whilecond140, label %while_body136, label %while_exit137

while_body136:                                    ; preds = %while_cond135
  %74 = load i64, ptr %"result$2", align 8
  %75 = load i64, ptr %"offset$3", align 8
  %76 = load i64, ptr %"k$6", align 8
  %addtmp141 = add i64 %75, %76
  %int_trunc142 = trunc i64 %addtmp141 to i32
  %int_sext143 = sext i32 %int_trunc142 to i64
  %77 = load i64, ptr %s, align 8
  %78 = load i64, ptr %search_start, align 8
  %79 = load i64, ptr %"k$6", align 8
  %addtmp144 = add i64 %78, %79
  %int_trunc145 = trunc i64 %addtmp144 to i32
  %int_sext146 = sext i32 %int_trunc145 to i64
  %index_addr147 = add i64 %77, %int_sext146
  %index_ptr148 = inttoptr i64 %index_addr147 to ptr
  %byte_val149 = load i8, ptr %index_ptr148, align 1
  %byte_val_ext150 = zext i8 %byte_val149 to i64
  %addr151 = add i64 %74, %int_sext143
  %write_ptr152 = inttoptr i64 %addr151 to ptr
  %byte_val153 = trunc i64 %byte_val_ext150 to i8
  store i8 %byte_val153, ptr %write_ptr152, align 1
  %80 = load i64, ptr %"k$6", align 8
  %addtmp154 = add i64 %80, 1
  %int_trunc155 = trunc i64 %addtmp154 to i32
  %int_sext156 = sext i32 %int_trunc155 to i64
  store i64 %int_sext156, ptr %"k$6", align 8
  br label %while_cond135

while_exit137:                                    ; preds = %while_cond135
  %81 = load i64, ptr %"offset$3", align 8
  %82 = load i64, ptr %before_len, align 8
  %addtmp157 = add i64 %81, %82
  %int_trunc158 = trunc i64 %addtmp157 to i32
  %int_sext159 = sext i32 %int_trunc158 to i64
  store i64 %int_sext159, ptr %"offset$3", align 8
  store i64 0, ptr %"k$7", align 8
  br label %while_cond160

while_cond160:                                    ; preds = %while_body161, %while_exit137
  %83 = load i64, ptr %"k$7", align 8
  %84 = load i64, ptr %new_len, align 8
  %cmptmp163 = icmp slt i64 %83, %84
  %zexttmp164 = zext i1 %cmptmp163 to i64
  %whilecond165 = icmp ne i64 %zexttmp164, 0
  br i1 %whilecond165, label %while_body161, label %while_exit162

while_body161:                                    ; preds = %while_cond160
  %85 = load i64, ptr %"result$2", align 8
  %86 = load i64, ptr %"offset$3", align 8
  %87 = load i64, ptr %"k$7", align 8
  %addtmp166 = add i64 %86, %87
  %int_trunc167 = trunc i64 %addtmp166 to i32
  %int_sext168 = sext i32 %int_trunc167 to i64
  %88 = load i64, ptr %new, align 8
  %89 = load i64, ptr %"k$7", align 8
  %index_addr169 = add i64 %88, %89
  %index_ptr170 = inttoptr i64 %index_addr169 to ptr
  %byte_val171 = load i8, ptr %index_ptr170, align 1
  %byte_val_ext172 = zext i8 %byte_val171 to i64
  %addr173 = add i64 %85, %int_sext168
  %write_ptr174 = inttoptr i64 %addr173 to ptr
  %byte_val175 = trunc i64 %byte_val_ext172 to i8
  store i8 %byte_val175, ptr %write_ptr174, align 1
  %90 = load i64, ptr %"k$7", align 8
  %addtmp176 = add i64 %90, 1
  %int_trunc177 = trunc i64 %addtmp176 to i32
  %int_sext178 = sext i32 %int_trunc177 to i64
  store i64 %int_sext178, ptr %"k$7", align 8
  br label %while_cond160

while_exit162:                                    ; preds = %while_cond160
  %91 = load i64, ptr %"offset$3", align 8
  %92 = load i64, ptr %new_len, align 8
  %addtmp179 = add i64 %91, %92
  %int_trunc180 = trunc i64 %addtmp179 to i32
  %int_sext181 = sext i32 %int_trunc180 to i64
  store i64 %int_sext181, ptr %"offset$3", align 8
  %93 = load i64, ptr %"idx$4", align 8
  %94 = load i64, ptr %old_len, align 8
  %addtmp182 = add i64 %93, %94
  %int_trunc183 = trunc i64 %addtmp182 to i32
  %int_sext184 = sext i32 %int_trunc183 to i64
  store i64 %int_sext184, ptr %search_start, align 8
  br label %while_cond98
}

define i64 @string_toLowerCase(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %ptr = alloca i64, align 8
  store i64 0, ptr %ptr, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  %2 = load i64, ptr %len, align 8
  %calltmp = call i64 @string_allocString(i64 %2)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %ptr, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %len, align 8
  %cmptmp = icmp slt i64 %3, %4
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %5 = load i64, ptr %s, align 8
  %6 = load i64, ptr %i, align 8
  %index_addr = add i64 %5, %6
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  store i64 %byte_val_ext, ptr %c, align 8
  %7 = load i64, ptr %c, align 8
  %cmptmp1 = icmp sge i64 %7, 65
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %8 = load i64, ptr %c, align 8
  %cmptmp3 = icmp sle i64 %8, 90
  %zexttmp4 = zext i1 %cmptmp3 to i64
  %andtmp = and i64 %zexttmp2, %zexttmp4
  %ifcond = icmp ne i64 %andtmp, 0
  br i1 %ifcond, label %then, label %else

while_exit:                                       ; preds = %while_cond
  %9 = load i64, ptr %ptr, align 8
  call void @nova_retain(i64 %9)
  %var_rel_load = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %9

then:                                             ; preds = %while_body
  %10 = load i64, ptr %ptr, align 8
  %11 = load i64, ptr %i, align 8
  %12 = load i64, ptr %c, align 8
  %addtmp = add i64 %12, 32
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %addr = add i64 %10, %11
  %write_ptr = inttoptr i64 %addr to ptr
  %byte_val5 = trunc i64 %int_sext to i8
  store i8 %byte_val5, ptr %write_ptr, align 1
  br label %ifcont

else:                                             ; preds = %while_body
  %13 = load i64, ptr %ptr, align 8
  %14 = load i64, ptr %i, align 8
  %15 = load i64, ptr %c, align 8
  %addr6 = add i64 %13, %14
  %write_ptr7 = inttoptr i64 %addr6 to ptr
  %byte_val8 = trunc i64 %15 to i8
  store i8 %byte_val8, ptr %write_ptr7, align 1
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  %16 = load i64, ptr %i, align 8
  %addtmp9 = add i64 %16, 1
  %int_trunc10 = trunc i64 %addtmp9 to i32
  %int_sext11 = sext i32 %int_trunc10 to i64
  store i64 %int_sext11, ptr %i, align 8
  br label %while_cond
}

define i64 @string_toUpperCase(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %ptr = alloca i64, align 8
  store i64 0, ptr %ptr, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  %2 = load i64, ptr %len, align 8
  %calltmp = call i64 @string_allocString(i64 %2)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %ptr, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont, %entry
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %len, align 8
  %cmptmp = icmp slt i64 %3, %4
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %5 = load i64, ptr %s, align 8
  %6 = load i64, ptr %i, align 8
  %index_addr = add i64 %5, %6
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  store i64 %byte_val_ext, ptr %c, align 8
  %7 = load i64, ptr %c, align 8
  %cmptmp1 = icmp sge i64 %7, 97
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %8 = load i64, ptr %c, align 8
  %cmptmp3 = icmp sle i64 %8, 122
  %zexttmp4 = zext i1 %cmptmp3 to i64
  %andtmp = and i64 %zexttmp2, %zexttmp4
  %ifcond = icmp ne i64 %andtmp, 0
  br i1 %ifcond, label %then, label %else

while_exit:                                       ; preds = %while_cond
  %9 = load i64, ptr %ptr, align 8
  call void @nova_retain(i64 %9)
  %var_rel_load = load i64, ptr %ptr, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %9

then:                                             ; preds = %while_body
  %10 = load i64, ptr %ptr, align 8
  %11 = load i64, ptr %i, align 8
  %12 = load i64, ptr %c, align 8
  %subtmp = sub i64 %12, 32
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %addr = add i64 %10, %11
  %write_ptr = inttoptr i64 %addr to ptr
  %byte_val5 = trunc i64 %int_sext to i8
  store i8 %byte_val5, ptr %write_ptr, align 1
  br label %ifcont

else:                                             ; preds = %while_body
  %13 = load i64, ptr %ptr, align 8
  %14 = load i64, ptr %i, align 8
  %15 = load i64, ptr %c, align 8
  %addr6 = add i64 %13, %14
  %write_ptr7 = inttoptr i64 %addr6 to ptr
  %byte_val8 = trunc i64 %15 to i8
  store i8 %byte_val8, ptr %write_ptr7, align 1
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  %16 = load i64, ptr %i, align 8
  %addtmp = add i64 %16, 1
  %int_trunc9 = trunc i64 %addtmp to i32
  %int_sext10 = sext i32 %int_trunc9 to i64
  store i64 %int_sext10, ptr %i, align 8
  br label %while_cond
}

define i64 @string_startsWith(i64 %0, i64 %1) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %prefix = alloca i64, align 8
  store i64 %1, ptr %prefix, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %p_len = alloca i64, align 8
  store i64 0, ptr %p_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %2 = load i64, ptr %s, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %3 = load i64, ptr %prefix, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %p_len, align 8
  %4 = load i64, ptr %s_len, align 8
  %5 = load i64, ptr %p_len, align 8
  %cmptmp = icmp slt i64 %4, %5
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont15, %ifcont
  %6 = load i64, ptr %i, align 8
  %7 = load i64, ptr %p_len, align 8
  %cmptmp5 = icmp slt i64 %6, %7
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %whilecond = icmp ne i64 %zexttmp6, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %8 = load i64, ptr %s, align 8
  %9 = load i64, ptr %i, align 8
  %index_addr = add i64 %8, %9
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %10 = load i64, ptr %prefix, align 8
  %11 = load i64, ptr %i, align 8
  %index_addr7 = add i64 %10, %11
  %index_ptr8 = inttoptr i64 %index_addr7 to ptr
  %byte_val9 = load i8, ptr %index_ptr8, align 1
  %byte_val_ext10 = zext i8 %byte_val9 to i64
  %cmptmp11 = icmp ne i64 %byte_val_ext, %byte_val_ext10
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %ifcond13 = icmp ne i64 %zexttmp12, 0
  br i1 %ifcond13, label %then14, label %ifcont15

while_exit:                                       ; preds = %while_cond
  ret i64 1

then14:                                           ; preds = %while_body
  ret i64 0

ifcont15:                                         ; preds = %while_body
  %12 = load i64, ptr %i, align 8
  %addtmp = add i64 %12, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

define i64 @string_endsWith(i64 %0, i64 %1) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %suffix = alloca i64, align 8
  store i64 %1, ptr %suffix, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %suf_len = alloca i64, align 8
  store i64 0, ptr %suf_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %2 = load i64, ptr %s, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %3 = load i64, ptr %suffix, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %suf_len, align 8
  %4 = load i64, ptr %s_len, align 8
  %5 = load i64, ptr %suf_len, align 8
  %cmptmp = icmp slt i64 %4, %5
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont17, %ifcont
  %6 = load i64, ptr %i, align 8
  %7 = load i64, ptr %suf_len, align 8
  %cmptmp5 = icmp slt i64 %6, %7
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %whilecond = icmp ne i64 %zexttmp6, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %8 = load i64, ptr %s, align 8
  %9 = load i64, ptr %s_len, align 8
  %10 = load i64, ptr %suf_len, align 8
  %subtmp = sub i64 %9, %10
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %11 = load i64, ptr %i, align 8
  %addtmp = add i64 %int_sext, %11
  %int_trunc7 = trunc i64 %addtmp to i32
  %int_sext8 = sext i32 %int_trunc7 to i64
  %index_addr = add i64 %8, %int_sext8
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %12 = load i64, ptr %suffix, align 8
  %13 = load i64, ptr %i, align 8
  %index_addr9 = add i64 %12, %13
  %index_ptr10 = inttoptr i64 %index_addr9 to ptr
  %byte_val11 = load i8, ptr %index_ptr10, align 1
  %byte_val_ext12 = zext i8 %byte_val11 to i64
  %cmptmp13 = icmp ne i64 %byte_val_ext, %byte_val_ext12
  %zexttmp14 = zext i1 %cmptmp13 to i64
  %ifcond15 = icmp ne i64 %zexttmp14, 0
  br i1 %ifcond15, label %then16, label %ifcont17

while_exit:                                       ; preds = %while_cond
  ret i64 1

then16:                                           ; preds = %while_body
  ret i64 0

ifcont17:                                         ; preds = %while_body
  %14 = load i64, ptr %i, align 8
  %addtmp18 = add i64 %14, 1
  %int_trunc19 = trunc i64 %addtmp18 to i32
  %int_sext20 = sext i32 %int_trunc19 to i64
  store i64 %int_sext20, ptr %i, align 8
  br label %while_cond
}

define i64 @string_contains(i64 %0, i64 %1) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %substr = alloca i64, align 8
  store i64 %1, ptr %substr, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %sub_len = alloca i64, align 8
  store i64 0, ptr %sub_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %is_match = alloca i64, align 8
  store i64 0, ptr %is_match, align 8
  %2 = load i64, ptr %s, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %3 = load i64, ptr %substr, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %sub_len, align 8
  %4 = load i64, ptr %s_len, align 8
  %5 = load i64, ptr %sub_len, align 8
  %cmptmp = icmp slt i64 %4, %5
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %sub_len, align 8
  %cmptmp5 = icmp eq i64 %6, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  ret i64 1

ifcont9:                                          ; preds = %ifcont
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont34, %ifcont9
  %7 = load i64, ptr %i, align 8
  %8 = load i64, ptr %s_len, align 8
  %9 = load i64, ptr %sub_len, align 8
  %subtmp = sub i64 %8, %9
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cmptmp10 = icmp sle i64 %7, %int_sext
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %whilecond = icmp ne i64 %zexttmp11, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  store i64 0, ptr %j, align 8
  store i64 1, ptr %is_match, align 8
  br label %while_cond12

while_exit:                                       ; preds = %while_cond
  ret i64 0

while_cond12:                                     ; preds = %ifcont28, %while_body
  %10 = load i64, ptr %j, align 8
  %11 = load i64, ptr %sub_len, align 8
  %cmptmp15 = icmp slt i64 %10, %11
  %zexttmp16 = zext i1 %cmptmp15 to i64
  %whilecond17 = icmp ne i64 %zexttmp16, 0
  br i1 %whilecond17, label %while_body13, label %while_exit14

while_body13:                                     ; preds = %while_cond12
  %12 = load i64, ptr %s, align 8
  %13 = load i64, ptr %i, align 8
  %14 = load i64, ptr %j, align 8
  %addtmp = add i64 %13, %14
  %int_trunc18 = trunc i64 %addtmp to i32
  %int_sext19 = sext i32 %int_trunc18 to i64
  %index_addr = add i64 %12, %int_sext19
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %15 = load i64, ptr %substr, align 8
  %16 = load i64, ptr %j, align 8
  %index_addr20 = add i64 %15, %16
  %index_ptr21 = inttoptr i64 %index_addr20 to ptr
  %byte_val22 = load i8, ptr %index_ptr21, align 1
  %byte_val_ext23 = zext i8 %byte_val22 to i64
  %cmptmp24 = icmp ne i64 %byte_val_ext, %byte_val_ext23
  %zexttmp25 = zext i1 %cmptmp24 to i64
  %ifcond26 = icmp ne i64 %zexttmp25, 0
  br i1 %ifcond26, label %then27, label %ifcont28

while_exit14:                                     ; preds = %then27, %while_cond12
  %17 = load i64, ptr %is_match, align 8
  %ifcond32 = icmp ne i64 %17, 0
  br i1 %ifcond32, label %then33, label %ifcont34

then27:                                           ; preds = %while_body13
  store i64 0, ptr %is_match, align 8
  br label %while_exit14

ifcont28:                                         ; preds = %while_body13
  %18 = load i64, ptr %j, align 8
  %addtmp29 = add i64 %18, 1
  %int_trunc30 = trunc i64 %addtmp29 to i32
  %int_sext31 = sext i32 %int_trunc30 to i64
  store i64 %int_sext31, ptr %j, align 8
  br label %while_cond12

then33:                                           ; preds = %while_exit14
  ret i64 1

ifcont34:                                         ; preds = %while_exit14
  %19 = load i64, ptr %i, align 8
  %addtmp35 = add i64 %19, 1
  %int_trunc36 = trunc i64 %addtmp35 to i32
  %int_sext37 = sext i32 %int_trunc36 to i64
  store i64 %int_sext37, ptr %i, align 8
  br label %while_cond
}

define i64 @string_indexOf(i64 %0, i64 %1) {
entry:
  %2 = call i64 @string_indexOfFrom(i64 %0, i64 %1, i64 0)
  ret i64 %2
}

define i64 @string_lastIndexOf(i64 %0, i64 %1) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %substr = alloca i64, align 8
  store i64 %1, ptr %substr, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %sub_len = alloca i64, align 8
  store i64 0, ptr %sub_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %is_match = alloca i64, align 8
  store i64 0, ptr %is_match, align 8
  %2 = load i64, ptr %s, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %3 = load i64, ptr %substr, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %sub_len, align 8
  %4 = load i64, ptr %s_len, align 8
  %5 = load i64, ptr %sub_len, align 8
  %cmptmp = icmp slt i64 %4, %5
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 -1

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %sub_len, align 8
  %cmptmp5 = icmp eq i64 %6, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ifcond7 = icmp ne i64 %zexttmp6, 0
  br i1 %ifcond7, label %then8, label %ifcont9

then8:                                            ; preds = %ifcont
  %7 = load i64, ptr %s_len, align 8
  ret i64 %7

ifcont9:                                          ; preds = %ifcont
  %8 = load i64, ptr %s_len, align 8
  %9 = load i64, ptr %sub_len, align 8
  %subtmp = sub i64 %8, %9
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont34, %ifcont9
  %10 = load i64, ptr %i, align 8
  %cmptmp10 = icmp sge i64 %10, 0
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %whilecond = icmp ne i64 %zexttmp11, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  store i64 0, ptr %j, align 8
  store i64 1, ptr %is_match, align 8
  br label %while_cond12

while_exit:                                       ; preds = %while_cond
  ret i64 -1

while_cond12:                                     ; preds = %ifcont28, %while_body
  %11 = load i64, ptr %j, align 8
  %12 = load i64, ptr %sub_len, align 8
  %cmptmp15 = icmp slt i64 %11, %12
  %zexttmp16 = zext i1 %cmptmp15 to i64
  %whilecond17 = icmp ne i64 %zexttmp16, 0
  br i1 %whilecond17, label %while_body13, label %while_exit14

while_body13:                                     ; preds = %while_cond12
  %13 = load i64, ptr %s, align 8
  %14 = load i64, ptr %i, align 8
  %15 = load i64, ptr %j, align 8
  %addtmp = add i64 %14, %15
  %int_trunc18 = trunc i64 %addtmp to i32
  %int_sext19 = sext i32 %int_trunc18 to i64
  %index_addr = add i64 %13, %int_sext19
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %16 = load i64, ptr %substr, align 8
  %17 = load i64, ptr %j, align 8
  %index_addr20 = add i64 %16, %17
  %index_ptr21 = inttoptr i64 %index_addr20 to ptr
  %byte_val22 = load i8, ptr %index_ptr21, align 1
  %byte_val_ext23 = zext i8 %byte_val22 to i64
  %cmptmp24 = icmp ne i64 %byte_val_ext, %byte_val_ext23
  %zexttmp25 = zext i1 %cmptmp24 to i64
  %ifcond26 = icmp ne i64 %zexttmp25, 0
  br i1 %ifcond26, label %then27, label %ifcont28

while_exit14:                                     ; preds = %then27, %while_cond12
  %18 = load i64, ptr %is_match, align 8
  %ifcond32 = icmp ne i64 %18, 0
  br i1 %ifcond32, label %then33, label %ifcont34

then27:                                           ; preds = %while_body13
  store i64 0, ptr %is_match, align 8
  br label %while_exit14

ifcont28:                                         ; preds = %while_body13
  %19 = load i64, ptr %j, align 8
  %addtmp29 = add i64 %19, 1
  %int_trunc30 = trunc i64 %addtmp29 to i32
  %int_sext31 = sext i32 %int_trunc30 to i64
  store i64 %int_sext31, ptr %j, align 8
  br label %while_cond12

then33:                                           ; preds = %while_exit14
  %20 = load i64, ptr %i, align 8
  ret i64 %20

ifcont34:                                         ; preds = %while_exit14
  %21 = load i64, ptr %i, align 8
  %subtmp35 = sub i64 %21, 1
  %int_trunc36 = trunc i64 %subtmp35 to i32
  %int_sext37 = sext i32 %int_trunc36 to i64
  store i64 %int_sext37, ptr %i, align 8
  br label %while_cond
}

define i64 @string_indexOfFrom(i64 %0, i64 %1, i64 %2) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %substr = alloca i64, align 8
  store i64 %1, ptr %substr, align 8
  %start = alloca i64, align 8
  store i64 %2, ptr %start, align 8
  %s_len = alloca i64, align 8
  store i64 0, ptr %s_len, align 8
  %sub_len = alloca i64, align 8
  store i64 0, ptr %sub_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %j = alloca i64, align 8
  store i64 0, ptr %j, align 8
  %is_match = alloca i64, align 8
  store i64 0, ptr %is_match, align 8
  %3 = load i64, ptr %s, align 8
  %len_addr = sub i64 %3, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %s_len, align 8
  %4 = load i64, ptr %substr, align 8
  %len_addr1 = sub i64 %4, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %sub_len, align 8
  %5 = load i64, ptr %s_len, align 8
  %6 = load i64, ptr %sub_len, align 8
  %cmptmp = icmp slt i64 %5, %6
  %zexttmp = zext i1 %cmptmp to i64
  %7 = load i64, ptr %start, align 8
  %8 = load i64, ptr %s_len, align 8
  %cmptmp5 = icmp sge i64 %7, %8
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %ortmp = or i64 %zexttmp, %zexttmp6
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 -1

ifcont:                                           ; preds = %entry
  %9 = load i64, ptr %sub_len, align 8
  %cmptmp7 = icmp eq i64 %9, 0
  %zexttmp8 = zext i1 %cmptmp7 to i64
  %ifcond9 = icmp ne i64 %zexttmp8, 0
  br i1 %ifcond9, label %then10, label %ifcont11

then10:                                           ; preds = %ifcont
  %10 = load i64, ptr %start, align 8
  ret i64 %10

ifcont11:                                         ; preds = %ifcont
  %11 = load i64, ptr %start, align 8
  store i64 %11, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont36, %ifcont11
  %12 = load i64, ptr %i, align 8
  %13 = load i64, ptr %s_len, align 8
  %14 = load i64, ptr %sub_len, align 8
  %subtmp = sub i64 %13, %14
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cmptmp12 = icmp sle i64 %12, %int_sext
  %zexttmp13 = zext i1 %cmptmp12 to i64
  %whilecond = icmp ne i64 %zexttmp13, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  store i64 0, ptr %j, align 8
  store i64 1, ptr %is_match, align 8
  br label %while_cond14

while_exit:                                       ; preds = %while_cond
  ret i64 -1

while_cond14:                                     ; preds = %ifcont30, %while_body
  %15 = load i64, ptr %j, align 8
  %16 = load i64, ptr %sub_len, align 8
  %cmptmp17 = icmp slt i64 %15, %16
  %zexttmp18 = zext i1 %cmptmp17 to i64
  %whilecond19 = icmp ne i64 %zexttmp18, 0
  br i1 %whilecond19, label %while_body15, label %while_exit16

while_body15:                                     ; preds = %while_cond14
  %17 = load i64, ptr %s, align 8
  %18 = load i64, ptr %i, align 8
  %19 = load i64, ptr %j, align 8
  %addtmp = add i64 %18, %19
  %int_trunc20 = trunc i64 %addtmp to i32
  %int_sext21 = sext i32 %int_trunc20 to i64
  %index_addr = add i64 %17, %int_sext21
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %20 = load i64, ptr %substr, align 8
  %21 = load i64, ptr %j, align 8
  %index_addr22 = add i64 %20, %21
  %index_ptr23 = inttoptr i64 %index_addr22 to ptr
  %byte_val24 = load i8, ptr %index_ptr23, align 1
  %byte_val_ext25 = zext i8 %byte_val24 to i64
  %cmptmp26 = icmp ne i64 %byte_val_ext, %byte_val_ext25
  %zexttmp27 = zext i1 %cmptmp26 to i64
  %ifcond28 = icmp ne i64 %zexttmp27, 0
  br i1 %ifcond28, label %then29, label %ifcont30

while_exit16:                                     ; preds = %then29, %while_cond14
  %22 = load i64, ptr %is_match, align 8
  %ifcond34 = icmp ne i64 %22, 0
  br i1 %ifcond34, label %then35, label %ifcont36

then29:                                           ; preds = %while_body15
  store i64 0, ptr %is_match, align 8
  br label %while_exit16

ifcont30:                                         ; preds = %while_body15
  %23 = load i64, ptr %j, align 8
  %addtmp31 = add i64 %23, 1
  %int_trunc32 = trunc i64 %addtmp31 to i32
  %int_sext33 = sext i32 %int_trunc32 to i64
  store i64 %int_sext33, ptr %j, align 8
  br label %while_cond14

then35:                                           ; preds = %while_exit16
  %24 = load i64, ptr %i, align 8
  ret i64 %24

ifcont36:                                         ; preds = %while_exit16
  %25 = load i64, ptr %i, align 8
  %addtmp37 = add i64 %25, 1
  %int_trunc38 = trunc i64 %addtmp37 to i32
  %int_sext39 = sext i32 %int_trunc38 to i64
  store i64 %int_sext39, ptr %i, align 8
  br label %while_cond
}

define i64 @string_eql(i64 %0, i64 %1) {
entry:
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %len_a = alloca i64, align 8
  store i64 0, ptr %len_a, align 8
  %len_b = alloca i64, align 8
  store i64 0, ptr %len_b, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %2 = load i64, ptr %a, align 8
  %cmptmp = icmp eq i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %3 = load i64, ptr %b, align 8
  %cmptmp1 = icmp eq i64 %3, 0
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ortmp = or i64 %zexttmp, %zexttmp2
  %ifcond = icmp ne i64 %ortmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %a, align 8
  %cmptmp3 = icmp eq i64 %4, 0
  %zexttmp4 = zext i1 %cmptmp3 to i64
  %5 = load i64, ptr %b, align 8
  %cmptmp5 = icmp eq i64 %5, 0
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %andtmp = and i64 %zexttmp4, %zexttmp6
  ret i64 %andtmp

ifcont:                                           ; preds = %entry
  %6 = load i64, ptr %a, align 8
  %len_addr = sub i64 %6, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len_a, align 8
  %7 = load i64, ptr %b, align 8
  %len_addr7 = sub i64 %7, 4
  %len_ptr8 = inttoptr i64 %len_addr7 to ptr
  %len_val9 = load i32, ptr %len_ptr8, align 4
  %len_val_ext10 = zext i32 %len_val9 to i64
  store i64 %len_val_ext10, ptr %len_b, align 8
  %8 = load i64, ptr %len_a, align 8
  %9 = load i64, ptr %len_b, align 8
  %cmptmp11 = icmp ne i64 %8, %9
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %ifcond13 = icmp ne i64 %zexttmp12, 0
  br i1 %ifcond13, label %then14, label %ifcont15

then14:                                           ; preds = %ifcont
  ret i64 0

ifcont15:                                         ; preds = %ifcont
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont26, %ifcont15
  %10 = load i64, ptr %i, align 8
  %11 = load i64, ptr %len_a, align 8
  %cmptmp16 = icmp slt i64 %10, %11
  %zexttmp17 = zext i1 %cmptmp16 to i64
  %whilecond = icmp ne i64 %zexttmp17, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %12 = load i64, ptr %a, align 8
  %13 = load i64, ptr %i, align 8
  %index_addr = add i64 %12, %13
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %14 = load i64, ptr %b, align 8
  %15 = load i64, ptr %i, align 8
  %index_addr18 = add i64 %14, %15
  %index_ptr19 = inttoptr i64 %index_addr18 to ptr
  %byte_val20 = load i8, ptr %index_ptr19, align 1
  %byte_val_ext21 = zext i8 %byte_val20 to i64
  %cmptmp22 = icmp ne i64 %byte_val_ext, %byte_val_ext21
  %zexttmp23 = zext i1 %cmptmp22 to i64
  %ifcond24 = icmp ne i64 %zexttmp23, 0
  br i1 %ifcond24, label %then25, label %ifcont26

while_exit:                                       ; preds = %while_cond
  ret i64 1

then25:                                           ; preds = %while_body
  ret i64 0

ifcont26:                                         ; preds = %while_body
  %16 = load i64, ptr %i, align 8
  %addtmp = add i64 %16, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond
}

define i64 @string_compare(i64 %0, i64 %1) {
entry:
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %len_a = alloca i64, align 8
  store i64 0, ptr %len_a, align 8
  %len_b = alloca i64, align 8
  store i64 0, ptr %len_b, align 8
  %min_len = alloca i64, align 8
  store i64 0, ptr %min_len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %char_a = alloca i64, align 8
  store i64 0, ptr %char_a, align 8
  %char_b = alloca i64, align 8
  store i64 0, ptr %char_b, align 8
  %2 = load i64, ptr %a, align 8
  %len_addr = sub i64 %2, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len_a, align 8
  %3 = load i64, ptr %b, align 8
  %len_addr1 = sub i64 %3, 4
  %len_ptr2 = inttoptr i64 %len_addr1 to ptr
  %len_val3 = load i32, ptr %len_ptr2, align 4
  %len_val_ext4 = zext i32 %len_val3 to i64
  store i64 %len_val_ext4, ptr %len_b, align 8
  %4 = load i64, ptr %len_a, align 8
  store i64 %4, ptr %min_len, align 8
  %5 = load i64, ptr %len_b, align 8
  %6 = load i64, ptr %len_a, align 8
  %cmptmp = icmp slt i64 %5, %6
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %7 = load i64, ptr %len_b, align 8
  store i64 %7, ptr %min_len, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont20, %ifcont
  %8 = load i64, ptr %i, align 8
  %9 = load i64, ptr %min_len, align 8
  %cmptmp5 = icmp slt i64 %8, %9
  %zexttmp6 = zext i1 %cmptmp5 to i64
  %whilecond = icmp ne i64 %zexttmp6, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %10 = load i64, ptr %a, align 8
  %11 = load i64, ptr %i, align 8
  %index_addr = add i64 %10, %11
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  store i64 %byte_val_ext, ptr %char_a, align 8
  %12 = load i64, ptr %b, align 8
  %13 = load i64, ptr %i, align 8
  %index_addr7 = add i64 %12, %13
  %index_ptr8 = inttoptr i64 %index_addr7 to ptr
  %byte_val9 = load i8, ptr %index_ptr8, align 1
  %byte_val_ext10 = zext i8 %byte_val9 to i64
  store i64 %byte_val_ext10, ptr %char_b, align 8
  %14 = load i64, ptr %char_a, align 8
  %15 = load i64, ptr %char_b, align 8
  %cmptmp11 = icmp slt i64 %14, %15
  %zexttmp12 = zext i1 %cmptmp11 to i64
  %ifcond13 = icmp ne i64 %zexttmp12, 0
  br i1 %ifcond13, label %then14, label %ifcont15

while_exit:                                       ; preds = %while_cond
  %16 = load i64, ptr %len_a, align 8
  %17 = load i64, ptr %len_b, align 8
  %cmptmp21 = icmp slt i64 %16, %17
  %zexttmp22 = zext i1 %cmptmp21 to i64
  %ifcond23 = icmp ne i64 %zexttmp22, 0
  br i1 %ifcond23, label %then24, label %ifcont25

then14:                                           ; preds = %while_body
  ret i64 -1

ifcont15:                                         ; preds = %while_body
  %18 = load i64, ptr %char_a, align 8
  %19 = load i64, ptr %char_b, align 8
  %cmptmp16 = icmp sgt i64 %18, %19
  %zexttmp17 = zext i1 %cmptmp16 to i64
  %ifcond18 = icmp ne i64 %zexttmp17, 0
  br i1 %ifcond18, label %then19, label %ifcont20

then19:                                           ; preds = %ifcont15
  ret i64 1

ifcont20:                                         ; preds = %ifcont15
  %20 = load i64, ptr %i, align 8
  %addtmp = add i64 %20, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

then24:                                           ; preds = %while_exit
  ret i64 -1

ifcont25:                                         ; preds = %while_exit
  %21 = load i64, ptr %len_a, align 8
  %22 = load i64, ptr %len_b, align 8
  %cmptmp26 = icmp sgt i64 %21, %22
  %zexttmp27 = zext i1 %cmptmp26 to i64
  %ifcond28 = icmp ne i64 %zexttmp27, 0
  br i1 %ifcond28, label %then29, label %ifcont30

then29:                                           ; preds = %ifcont25
  ret i64 1

ifcont30:                                         ; preds = %ifcont25
  ret i64 0
}

define i64 @string_hash(i64 %0) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %h = alloca i64, align 8
  store i64 0, ptr %h, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  store i64 5381, ptr %h, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %2 = load i64, ptr %i, align 8
  %3 = load i64, ptr %len, align 8
  %cmptmp = icmp slt i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %4 = load i64, ptr %s, align 8
  %5 = load i64, ptr %i, align 8
  %index_addr = add i64 %4, %5
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  store i64 %byte_val_ext, ptr %c, align 8
  %6 = load i64, ptr %h, align 8
  %shltmp = shl i64 %6, 5
  %int_trunc = trunc i64 %shltmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %7 = load i64, ptr %h, align 8
  %addtmp = add i64 %int_sext, %7
  %int_trunc1 = trunc i64 %addtmp to i32
  %int_sext2 = sext i32 %int_trunc1 to i64
  %8 = load i64, ptr %c, align 8
  %addtmp3 = add i64 %int_sext2, %8
  %int_trunc4 = trunc i64 %addtmp3 to i32
  %int_sext5 = sext i32 %int_trunc4 to i64
  store i64 %int_sext5, ptr %h, align 8
  %9 = load i64, ptr %i, align 8
  %addtmp6 = add i64 %9, 1
  %int_trunc7 = trunc i64 %addtmp6 to i32
  %int_sext8 = sext i32 %int_trunc7 to i64
  store i64 %int_sext8, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %10 = load i64, ptr %h, align 8
  ret i64 %10
}

define i64 @string_parseI64(i64 %0) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %LONG_MIN = alloca i64, align 8
  store i64 0, ptr %LONG_MIN, align 8
  %LONG_MAX = alloca i64, align 8
  store i64 0, ptr %LONG_MAX, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %neg = alloca i64, align 8
  store i64 0, ptr %neg, align 8
  %limit = alloca i64, align 8
  store i64 0, ptr %limit, align 8
  %multmin = alloca i64, align 8
  store i64 0, ptr %multmin, align 8
  %acc = alloca i64, align 8
  store i64 0, ptr %acc, align 8
  %any = alloca i64, align 8
  store i64 0, ptr %any, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %d = alloca i64, align 8
  store i64 0, ptr %d, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  %2 = load i64, ptr %len, align 8
  %cmptmp = icmp eq i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  store i64 -9223372036854775808, ptr %LONG_MIN, align 8
  store i64 9223372036854775807, ptr %LONG_MAX, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %neg, align 8
  %3 = load i64, ptr %s, align 8
  %index_addr = add i64 %3, 0
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %cmptmp1 = icmp eq i64 %byte_val_ext, 45
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ifcond3 = icmp ne i64 %zexttmp2, 0
  br i1 %ifcond3, label %then4, label %else

then4:                                            ; preds = %ifcont
  store i64 1, ptr %neg, align 8
  store i64 1, ptr %i, align 8
  br label %ifcont5

else:                                             ; preds = %ifcont
  %4 = load i64, ptr %s, align 8
  %index_addr6 = add i64 %4, 0
  %index_ptr7 = inttoptr i64 %index_addr6 to ptr
  %byte_val8 = load i8, ptr %index_ptr7, align 1
  %byte_val_ext9 = zext i8 %byte_val8 to i64
  %cmptmp10 = icmp eq i64 %byte_val_ext9, 43
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %ifcond12 = icmp ne i64 %zexttmp11, 0
  br i1 %ifcond12, label %then13, label %ifcont14

ifcont5:                                          ; preds = %ifcont14, %then4
  %5 = load i64, ptr %LONG_MAX, align 8
  %subtmp = sub i64 0, %5
  store i64 %subtmp, ptr %limit, align 8
  %6 = load i64, ptr %neg, align 8
  %ifcond15 = icmp ne i64 %6, 0
  br i1 %ifcond15, label %then16, label %ifcont17

then13:                                           ; preds = %else
  store i64 1, ptr %i, align 8
  br label %ifcont14

ifcont14:                                         ; preds = %then13, %else
  br label %ifcont5

then16:                                           ; preds = %ifcont5
  %7 = load i64, ptr %LONG_MIN, align 8
  store i64 %7, ptr %limit, align 8
  br label %ifcont17

ifcont17:                                         ; preds = %then16, %ifcont5
  %8 = load i64, ptr %limit, align 8
  br i1 false, label %trap_panic, label %trap_ok

trap_panic:                                       ; preds = %ifcont17
  call void @nova_panic_cstr(ptr @trap_msg)
  unreachable

trap_ok:                                          ; preds = %ifcont17
  %div_lmin = icmp eq i64 %8, -9223372036854775808
  %div_ovf = and i1 %div_lmin, false
  br i1 %div_ovf, label %trap_panic18, label %trap_ok19

trap_panic18:                                     ; preds = %trap_ok
  call void @nova_panic_cstr(ptr @trap_msg.120)
  unreachable

trap_ok19:                                        ; preds = %trap_ok
  %divtmp = sdiv i64 %8, 10
  store i64 %divtmp, ptr %multmin, align 8
  store i64 0, ptr %acc, align 8
  store i64 0, ptr %any, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont33, %trap_ok19
  %9 = load i64, ptr %i, align 8
  %10 = load i64, ptr %len, align 8
  %cmptmp20 = icmp slt i64 %9, %10
  %zexttmp21 = zext i1 %cmptmp20 to i64
  %whilecond = icmp ne i64 %zexttmp21, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %11 = load i64, ptr %s, align 8
  %12 = load i64, ptr %i, align 8
  %index_addr22 = add i64 %11, %12
  %index_ptr23 = inttoptr i64 %index_addr22 to ptr
  %byte_val24 = load i8, ptr %index_ptr23, align 1
  %byte_val_ext25 = zext i8 %byte_val24 to i64
  store i64 %byte_val_ext25, ptr %c, align 8
  %13 = load i64, ptr %c, align 8
  %cmptmp26 = icmp slt i64 %13, 48
  %zexttmp27 = zext i1 %cmptmp26 to i64
  %14 = load i64, ptr %c, align 8
  %cmptmp28 = icmp sgt i64 %14, 57
  %zexttmp29 = zext i1 %cmptmp28 to i64
  %ortmp = or i64 %zexttmp27, %zexttmp29
  %ifcond30 = icmp ne i64 %ortmp, 0
  br i1 %ifcond30, label %then31, label %else32

while_exit:                                       ; preds = %while_cond
  %15 = load i64, ptr %any, align 8
  %nottmp = icmp eq i64 %15, 0
  %zexttmp55 = zext i1 %nottmp to i64
  %ifcond56 = icmp ne i64 %zexttmp55, 0
  br i1 %ifcond56, label %then57, label %ifcont58

then31:                                           ; preds = %while_body
  %16 = load i64, ptr %len, align 8
  store i64 %16, ptr %i, align 8
  br label %ifcont33

else32:                                           ; preds = %while_body
  %17 = load i64, ptr %c, align 8
  %subtmp34 = sub i64 %17, 48
  %int_trunc = trunc i64 %subtmp34 to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %d, align 8
  %18 = load i64, ptr %acc, align 8
  %19 = load i64, ptr %multmin, align 8
  %cmptmp35 = icmp slt i64 %18, %19
  %zexttmp36 = zext i1 %cmptmp35 to i64
  %ifcond37 = icmp ne i64 %zexttmp36, 0
  br i1 %ifcond37, label %then38, label %ifcont39

ifcont33:                                         ; preds = %ifcont47, %then31
  br label %while_cond

then38:                                           ; preds = %else32
  %20 = load i64, ptr %neg, align 8
  %ifcond40 = icmp ne i64 %20, 0
  br i1 %ifcond40, label %then41, label %ifcont42

ifcont39:                                         ; preds = %else32
  %21 = load i64, ptr %acc, align 8
  %multmp = mul i64 %21, 10
  store i64 %multmp, ptr %acc, align 8
  %22 = load i64, ptr %acc, align 8
  %23 = load i64, ptr %limit, align 8
  %24 = load i64, ptr %d, align 8
  %addtmp = add i64 %23, %24
  %cmptmp43 = icmp slt i64 %22, %addtmp
  %zexttmp44 = zext i1 %cmptmp43 to i64
  %ifcond45 = icmp ne i64 %zexttmp44, 0
  br i1 %ifcond45, label %then46, label %ifcont47

then41:                                           ; preds = %then38
  %25 = load i64, ptr %LONG_MIN, align 8
  ret i64 %25

ifcont42:                                         ; preds = %then38
  %26 = load i64, ptr %LONG_MAX, align 8
  ret i64 %26

then46:                                           ; preds = %ifcont39
  %27 = load i64, ptr %neg, align 8
  %ifcond48 = icmp ne i64 %27, 0
  br i1 %ifcond48, label %then49, label %ifcont50

ifcont47:                                         ; preds = %ifcont39
  %28 = load i64, ptr %acc, align 8
  %29 = load i64, ptr %d, align 8
  %subtmp51 = sub i64 %28, %29
  store i64 %subtmp51, ptr %acc, align 8
  store i64 1, ptr %any, align 8
  %30 = load i64, ptr %i, align 8
  %addtmp52 = add i64 %30, 1
  %int_trunc53 = trunc i64 %addtmp52 to i32
  %int_sext54 = sext i32 %int_trunc53 to i64
  store i64 %int_sext54, ptr %i, align 8
  br label %ifcont33

then49:                                           ; preds = %then46
  %31 = load i64, ptr %LONG_MIN, align 8
  ret i64 %31

ifcont50:                                         ; preds = %then46
  %32 = load i64, ptr %LONG_MAX, align 8
  ret i64 %32

then57:                                           ; preds = %while_exit
  ret i64 0

ifcont58:                                         ; preds = %while_exit
  %33 = load i64, ptr %neg, align 8
  %ifcond59 = icmp ne i64 %33, 0
  br i1 %ifcond59, label %then60, label %ifcont61

then60:                                           ; preds = %ifcont58
  %34 = load i64, ptr %acc, align 8
  ret i64 %34

ifcont61:                                         ; preds = %ifcont58
  %35 = load i64, ptr %acc, align 8
  %subtmp62 = sub i64 0, %35
  ret i64 %subtmp62
}

define i64 @string_parseFloat(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %parsed = alloca i64, align 8
  store i64 0, ptr %parsed, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %neg = alloca i64, align 8
  store i64 0, ptr %neg, align 8
  %intPart = alloca double, align 8
  store double 0.000000e+00, ptr %intPart, align 8
  %frac = alloca double, align 8
  store double 0.000000e+00, ptr %frac, align 8
  %scale = alloca double, align 8
  store double 0.000000e+00, ptr %scale, align 8
  %result = alloca double, align 8
  store double 0.000000e+00, ptr %result, align 8
  %1 = load i64, ptr %s, align 8
  %calltmp = call i64 @string_parseDouble(i64 %1)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %parsed, align 8
  %2 = load i64, ptr %parsed, align 8
  %cmptmp = icmp ne i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %3 = load i64, ptr %parsed, align 8
  %valopt_unbox = call i64 @nova_valopt_unbox(i64 %3)
  %var_rel_load = load i64, ptr %parsed, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %valopt_unbox

ifcont:                                           ; preds = %entry
  %4 = load i64, ptr %s, align 8
  %len_addr = sub i64 %4, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  store i64 0, ptr %i, align 8
  store i64 0, ptr %neg, align 8
  %5 = load i64, ptr %len, align 8
  %cmptmp1 = icmp sgt i64 %5, 0
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %6 = load i64, ptr %s, align 8
  %index_addr = add i64 %6, 0
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %cmptmp3 = icmp eq i64 %byte_val_ext, 45
  %zexttmp4 = zext i1 %cmptmp3 to i64
  %andtmp = and i64 %zexttmp2, %zexttmp4
  %ifcond5 = icmp ne i64 %andtmp, 0
  br i1 %ifcond5, label %then6, label %ifcont7

then6:                                            ; preds = %ifcont
  store i64 1, ptr %neg, align 8
  store i64 1, ptr %i, align 8
  br label %ifcont7

ifcont7:                                          ; preds = %then6, %ifcont
  store double 0.000000e+00, ptr %intPart, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont32, %ifcont7
  %7 = load i64, ptr %i, align 8
  %8 = load i64, ptr %len, align 8
  %cmptmp8 = icmp slt i64 %7, %8
  %zexttmp9 = zext i1 %cmptmp8 to i64
  %9 = load i64, ptr %s, align 8
  %10 = load i64, ptr %i, align 8
  %index_addr10 = add i64 %9, %10
  %index_ptr11 = inttoptr i64 %index_addr10 to ptr
  %byte_val12 = load i8, ptr %index_ptr11, align 1
  %byte_val_ext13 = zext i8 %byte_val12 to i64
  %cmptmp14 = icmp ne i64 %byte_val_ext13, 46
  %zexttmp15 = zext i1 %cmptmp14 to i64
  %andtmp16 = and i64 %zexttmp9, %zexttmp15
  %whilecond = icmp ne i64 %andtmp16, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %11 = load i64, ptr %s, align 8
  %12 = load i64, ptr %i, align 8
  %index_addr17 = add i64 %11, %12
  %index_ptr18 = inttoptr i64 %index_addr17 to ptr
  %byte_val19 = load i8, ptr %index_ptr18, align 1
  %byte_val_ext20 = zext i8 %byte_val19 to i64
  %cmptmp21 = icmp sge i64 %byte_val_ext20, 48
  %zexttmp22 = zext i1 %cmptmp21 to i64
  %13 = load i64, ptr %s, align 8
  %14 = load i64, ptr %i, align 8
  %index_addr23 = add i64 %13, %14
  %index_ptr24 = inttoptr i64 %index_addr23 to ptr
  %byte_val25 = load i8, ptr %index_ptr24, align 1
  %byte_val_ext26 = zext i8 %byte_val25 to i64
  %cmptmp27 = icmp sle i64 %byte_val_ext26, 57
  %zexttmp28 = zext i1 %cmptmp27 to i64
  %andtmp29 = and i64 %zexttmp22, %zexttmp28
  %ifcond30 = icmp ne i64 %andtmp29, 0
  br i1 %ifcond30, label %then31, label %ifcont32

while_exit:                                       ; preds = %while_cond
  store double 0.000000e+00, ptr %frac, align 8
  store double 1.000000e+00, ptr %scale, align 8
  %15 = load i64, ptr %i, align 8
  %16 = load i64, ptr %len, align 8
  %cmptmp39 = icmp slt i64 %15, %16
  %zexttmp40 = zext i1 %cmptmp39 to i64
  %17 = load i64, ptr %s, align 8
  %18 = load i64, ptr %i, align 8
  %index_addr41 = add i64 %17, %18
  %index_ptr42 = inttoptr i64 %index_addr41 to ptr
  %byte_val43 = load i8, ptr %index_ptr42, align 1
  %byte_val_ext44 = zext i8 %byte_val43 to i64
  %cmptmp45 = icmp eq i64 %byte_val_ext44, 46
  %zexttmp46 = zext i1 %cmptmp45 to i64
  %andtmp47 = and i64 %zexttmp40, %zexttmp46
  %ifcond48 = icmp ne i64 %andtmp47, 0
  br i1 %ifcond48, label %then49, label %ifcont50

then31:                                           ; preds = %while_body
  %19 = load double, ptr %intPart, align 8
  %fmultmp = fmul double %19, 1.000000e+01
  %20 = load i64, ptr %s, align 8
  %21 = load i64, ptr %i, align 8
  %index_addr33 = add i64 %20, %21
  %index_ptr34 = inttoptr i64 %index_addr33 to ptr
  %byte_val35 = load i8, ptr %index_ptr34, align 1
  %byte_val_ext36 = zext i8 %byte_val35 to i64
  %subtmp = sub i64 %byte_val_ext36, 48
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cast_i2f = sitofp i64 %int_sext to double
  %cast_i2f_val = bitcast double %cast_i2f to i64
  %r_double = bitcast i64 %cast_i2f_val to double
  %faddtmp = fadd double %fmultmp, %r_double
  store double %faddtmp, ptr %intPart, align 8
  br label %ifcont32

ifcont32:                                         ; preds = %then31, %while_body
  %22 = load i64, ptr %i, align 8
  %addtmp = add i64 %22, 1
  %int_trunc37 = trunc i64 %addtmp to i32
  %int_sext38 = sext i32 %int_trunc37 to i64
  store i64 %int_sext38, ptr %i, align 8
  br label %while_cond

then49:                                           ; preds = %while_exit
  %23 = load i64, ptr %i, align 8
  %addtmp51 = add i64 %23, 1
  %int_trunc52 = trunc i64 %addtmp51 to i32
  %int_sext53 = sext i32 %int_trunc52 to i64
  store i64 %int_sext53, ptr %i, align 8
  br label %while_cond54

ifcont50:                                         ; preds = %while_exit56, %while_exit
  %24 = load double, ptr %intPart, align 8
  %25 = load double, ptr %frac, align 8
  %faddtmp90 = fadd double %24, %25
  store double %faddtmp90, ptr %result, align 8
  %26 = load i64, ptr %neg, align 8
  %ifcond91 = icmp ne i64 %26, 0
  br i1 %ifcond91, label %then92, label %ifcont93

while_cond54:                                     ; preds = %ifcont75, %then49
  %27 = load i64, ptr %i, align 8
  %28 = load i64, ptr %len, align 8
  %cmptmp57 = icmp slt i64 %27, %28
  %zexttmp58 = zext i1 %cmptmp57 to i64
  %whilecond59 = icmp ne i64 %zexttmp58, 0
  br i1 %whilecond59, label %while_body55, label %while_exit56

while_body55:                                     ; preds = %while_cond54
  %29 = load i64, ptr %s, align 8
  %30 = load i64, ptr %i, align 8
  %index_addr60 = add i64 %29, %30
  %index_ptr61 = inttoptr i64 %index_addr60 to ptr
  %byte_val62 = load i8, ptr %index_ptr61, align 1
  %byte_val_ext63 = zext i8 %byte_val62 to i64
  %cmptmp64 = icmp sge i64 %byte_val_ext63, 48
  %zexttmp65 = zext i1 %cmptmp64 to i64
  %31 = load i64, ptr %s, align 8
  %32 = load i64, ptr %i, align 8
  %index_addr66 = add i64 %31, %32
  %index_ptr67 = inttoptr i64 %index_addr66 to ptr
  %byte_val68 = load i8, ptr %index_ptr67, align 1
  %byte_val_ext69 = zext i8 %byte_val68 to i64
  %cmptmp70 = icmp sle i64 %byte_val_ext69, 57
  %zexttmp71 = zext i1 %cmptmp70 to i64
  %andtmp72 = and i64 %zexttmp65, %zexttmp71
  %ifcond73 = icmp ne i64 %andtmp72, 0
  br i1 %ifcond73, label %then74, label %ifcont75

while_exit56:                                     ; preds = %while_cond54
  br label %ifcont50

then74:                                           ; preds = %while_body55
  %33 = load double, ptr %scale, align 8
  %fdivtmp = fdiv double %33, 1.000000e+01
  store double %fdivtmp, ptr %scale, align 8
  %34 = load double, ptr %frac, align 8
  %35 = load i64, ptr %s, align 8
  %36 = load i64, ptr %i, align 8
  %index_addr76 = add i64 %35, %36
  %index_ptr77 = inttoptr i64 %index_addr76 to ptr
  %byte_val78 = load i8, ptr %index_ptr77, align 1
  %byte_val_ext79 = zext i8 %byte_val78 to i64
  %subtmp80 = sub i64 %byte_val_ext79, 48
  %int_trunc81 = trunc i64 %subtmp80 to i32
  %int_sext82 = sext i32 %int_trunc81 to i64
  %cast_i2f83 = sitofp i64 %int_sext82 to double
  %cast_i2f_val84 = bitcast double %cast_i2f83 to i64
  %37 = load double, ptr %scale, align 8
  %l_double = bitcast i64 %cast_i2f_val84 to double
  %fmultmp85 = fmul double %l_double, %37
  %faddtmp86 = fadd double %34, %fmultmp85
  store double %faddtmp86, ptr %frac, align 8
  br label %ifcont75

ifcont75:                                         ; preds = %then74, %while_body55
  %38 = load i64, ptr %i, align 8
  %addtmp87 = add i64 %38, 1
  %int_trunc88 = trunc i64 %addtmp87 to i32
  %int_sext89 = sext i32 %int_trunc88 to i64
  store i64 %int_sext89, ptr %i, align 8
  br label %while_cond54

then92:                                           ; preds = %ifcont50
  %39 = load double, ptr %result, align 8
  %fsubtmp = fsub double 0.000000e+00, %39
  store double %fsubtmp, ptr %result, align 8
  br label %ifcont93

ifcont93:                                         ; preds = %then92, %ifcont50
  %40 = load double, ptr %result, align 8
  %ret_double_to_val = bitcast double %40 to i64
  %var_rel_load94 = load i64, ptr %parsed, align 8
  call void @nova_release(i64 %var_rel_load94, ptr null)
  ret i64 %ret_double_to_val
}

define i64 @string_parseLong(i64 %0) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %neg = alloca i64, align 8
  store i64 0, ptr %neg, align 8
  %LONG_MIN = alloca i64, align 8
  store i64 0, ptr %LONG_MIN, align 8
  %LONG_MAX = alloca i64, align 8
  store i64 0, ptr %LONG_MAX, align 8
  %limit = alloca i64, align 8
  store i64 0, ptr %limit, align 8
  %multmin = alloca i64, align 8
  store i64 0, ptr %multmin, align 8
  %acc = alloca i64, align 8
  store i64 0, ptr %acc, align 8
  %c = alloca i64, align 8
  store i64 0, ptr %c, align 8
  %d = alloca i64, align 8
  store i64 0, ptr %d, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  %2 = load i64, ptr %len, align 8
  %cmptmp = icmp eq i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  store i64 0, ptr %i, align 8
  store i64 0, ptr %neg, align 8
  %3 = load i64, ptr %s, align 8
  %index_addr = add i64 %3, 0
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %cmptmp1 = icmp eq i64 %byte_val_ext, 45
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ifcond3 = icmp ne i64 %zexttmp2, 0
  br i1 %ifcond3, label %then4, label %else

then4:                                            ; preds = %ifcont
  store i64 1, ptr %neg, align 8
  store i64 1, ptr %i, align 8
  br label %ifcont5

else:                                             ; preds = %ifcont
  %4 = load i64, ptr %s, align 8
  %index_addr6 = add i64 %4, 0
  %index_ptr7 = inttoptr i64 %index_addr6 to ptr
  %byte_val8 = load i8, ptr %index_ptr7, align 1
  %byte_val_ext9 = zext i8 %byte_val8 to i64
  %cmptmp10 = icmp eq i64 %byte_val_ext9, 43
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %ifcond12 = icmp ne i64 %zexttmp11, 0
  br i1 %ifcond12, label %then13, label %ifcont14

ifcont5:                                          ; preds = %ifcont14, %then4
  %5 = load i64, ptr %i, align 8
  %6 = load i64, ptr %len, align 8
  %cmptmp15 = icmp sge i64 %5, %6
  %zexttmp16 = zext i1 %cmptmp15 to i64
  %ifcond17 = icmp ne i64 %zexttmp16, 0
  br i1 %ifcond17, label %then18, label %ifcont19

then13:                                           ; preds = %else
  store i64 1, ptr %i, align 8
  br label %ifcont14

ifcont14:                                         ; preds = %then13, %else
  br label %ifcont5

then18:                                           ; preds = %ifcont5
  ret i64 0

ifcont19:                                         ; preds = %ifcont5
  store i64 -9223372036854775808, ptr %LONG_MIN, align 8
  store i64 9223372036854775807, ptr %LONG_MAX, align 8
  %7 = load i64, ptr %LONG_MAX, align 8
  %subtmp = sub i64 0, %7
  store i64 %subtmp, ptr %limit, align 8
  %8 = load i64, ptr %neg, align 8
  %ifcond20 = icmp ne i64 %8, 0
  br i1 %ifcond20, label %then21, label %ifcont22

then21:                                           ; preds = %ifcont19
  %9 = load i64, ptr %LONG_MIN, align 8
  store i64 %9, ptr %limit, align 8
  br label %ifcont22

ifcont22:                                         ; preds = %then21, %ifcont19
  %10 = load i64, ptr %limit, align 8
  br i1 false, label %trap_panic, label %trap_ok

trap_panic:                                       ; preds = %ifcont22
  call void @nova_panic_cstr(ptr @trap_msg.121)
  unreachable

trap_ok:                                          ; preds = %ifcont22
  %div_lmin = icmp eq i64 %10, -9223372036854775808
  %div_ovf = and i1 %div_lmin, false
  br i1 %div_ovf, label %trap_panic23, label %trap_ok24

trap_panic23:                                     ; preds = %trap_ok
  call void @nova_panic_cstr(ptr @trap_msg.122)
  unreachable

trap_ok24:                                        ; preds = %trap_ok
  %divtmp = sdiv i64 %10, 10
  store i64 %divtmp, ptr %multmin, align 8
  store i64 0, ptr %acc, align 8
  br label %while_cond

while_cond:                                       ; preds = %ifcont48, %trap_ok24
  %11 = load i64, ptr %i, align 8
  %12 = load i64, ptr %len, align 8
  %cmptmp25 = icmp slt i64 %11, %12
  %zexttmp26 = zext i1 %cmptmp25 to i64
  %whilecond = icmp ne i64 %zexttmp26, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %13 = load i64, ptr %s, align 8
  %14 = load i64, ptr %i, align 8
  %index_addr27 = add i64 %13, %14
  %index_ptr28 = inttoptr i64 %index_addr27 to ptr
  %byte_val29 = load i8, ptr %index_ptr28, align 1
  %byte_val_ext30 = zext i8 %byte_val29 to i64
  store i64 %byte_val_ext30, ptr %c, align 8
  %15 = load i64, ptr %c, align 8
  %cmptmp31 = icmp slt i64 %15, 48
  %zexttmp32 = zext i1 %cmptmp31 to i64
  %16 = load i64, ptr %c, align 8
  %cmptmp33 = icmp sgt i64 %16, 57
  %zexttmp34 = zext i1 %cmptmp33 to i64
  %ortmp = or i64 %zexttmp32, %zexttmp34
  %ifcond35 = icmp ne i64 %ortmp, 0
  br i1 %ifcond35, label %then36, label %ifcont37

while_exit:                                       ; preds = %while_cond
  %17 = load i64, ptr %neg, align 8
  %ifcond53 = icmp ne i64 %17, 0
  br i1 %ifcond53, label %then54, label %ifcont55

then36:                                           ; preds = %while_body
  ret i64 0

ifcont37:                                         ; preds = %while_body
  %18 = load i64, ptr %c, align 8
  %subtmp38 = sub i64 %18, 48
  %int_trunc = trunc i64 %subtmp38 to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %d, align 8
  %19 = load i64, ptr %acc, align 8
  %20 = load i64, ptr %multmin, align 8
  %cmptmp39 = icmp slt i64 %19, %20
  %zexttmp40 = zext i1 %cmptmp39 to i64
  %ifcond41 = icmp ne i64 %zexttmp40, 0
  br i1 %ifcond41, label %then42, label %ifcont43

then42:                                           ; preds = %ifcont37
  ret i64 0

ifcont43:                                         ; preds = %ifcont37
  %21 = load i64, ptr %acc, align 8
  %multmp = mul i64 %21, 10
  store i64 %multmp, ptr %acc, align 8
  %22 = load i64, ptr %acc, align 8
  %23 = load i64, ptr %limit, align 8
  %24 = load i64, ptr %d, align 8
  %addtmp = add i64 %23, %24
  %cmptmp44 = icmp slt i64 %22, %addtmp
  %zexttmp45 = zext i1 %cmptmp44 to i64
  %ifcond46 = icmp ne i64 %zexttmp45, 0
  br i1 %ifcond46, label %then47, label %ifcont48

then47:                                           ; preds = %ifcont43
  ret i64 0

ifcont48:                                         ; preds = %ifcont43
  %25 = load i64, ptr %acc, align 8
  %26 = load i64, ptr %d, align 8
  %subtmp49 = sub i64 %25, %26
  store i64 %subtmp49, ptr %acc, align 8
  %27 = load i64, ptr %i, align 8
  %addtmp50 = add i64 %27, 1
  %int_trunc51 = trunc i64 %addtmp50 to i32
  %int_sext52 = sext i32 %int_trunc51 to i64
  store i64 %int_sext52, ptr %i, align 8
  br label %while_cond

then54:                                           ; preds = %while_exit
  %28 = load i64, ptr %acc, align 8
  %valopt_box = call i64 @nova_valopt_box(i64 %28)
  ret i64 %valopt_box

ifcont55:                                         ; preds = %while_exit
  %29 = load i64, ptr %acc, align 8
  %subtmp56 = sub i64 0, %29
  %valopt_box57 = call i64 @nova_valopt_box(i64 %subtmp56)
  ret i64 %valopt_box57
}

define i64 @string_parseInt(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %v = alloca i64, align 8
  store i64 0, ptr %v, align 8
  %INT_MIN = alloca i64, align 8
  store i64 0, ptr %INT_MIN, align 8
  %INT_MAX = alloca i64, align 8
  store i64 0, ptr %INT_MAX, align 8
  %1 = load i64, ptr %s, align 8
  %calltmp = call i64 @string_parseLong(i64 %1)
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 %calltmp, ptr %v, align 8
  %2 = load i64, ptr %v, align 8
  %cmptmp = icmp eq i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %var_rel_load = load i64, ptr %v, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 0

ifcont:                                           ; preds = %entry
  store i64 -2147483648, ptr %INT_MIN, align 8
  store i64 2147483647, ptr %INT_MAX, align 8
  %3 = load i64, ptr %v, align 8
  %valopt_unbox = call i64 @nova_valopt_unbox(i64 %3)
  %4 = load i64, ptr %INT_MIN, align 8
  %cmptmp1 = icmp slt i64 %valopt_unbox, %4
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %5 = load i64, ptr %v, align 8
  %valopt_unbox3 = call i64 @nova_valopt_unbox(i64 %5)
  %6 = load i64, ptr %INT_MAX, align 8
  %cmptmp4 = icmp sgt i64 %valopt_unbox3, %6
  %zexttmp5 = zext i1 %cmptmp4 to i64
  %ortmp = or i64 %zexttmp2, %zexttmp5
  %ifcond6 = icmp ne i64 %ortmp, 0
  br i1 %ifcond6, label %then7, label %ifcont8

then7:                                            ; preds = %ifcont
  %var_rel_load9 = load i64, ptr %v, align 8
  call void @nova_release(i64 %var_rel_load9, ptr null)
  ret i64 0

ifcont8:                                          ; preds = %ifcont
  %7 = load i64, ptr %v, align 8
  %valopt_unbox10 = call i64 @nova_valopt_unbox(i64 %7)
  %int_trunc = trunc i64 %valopt_unbox10 to i32
  %int_sext = sext i32 %int_trunc to i64
  %valopt_box = call i64 @nova_valopt_box(i64 %int_sext)
  %var_rel_load11 = load i64, ptr %v, align 8
  call void @nova_release(i64 %var_rel_load11, ptr null)
  ret i64 %valopt_box
}

define i64 @string_parseDouble(i64 %0) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 8
  %len = alloca i64, align 8
  store i64 0, ptr %len, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %neg = alloca i64, align 8
  store i64 0, ptr %neg, align 8
  %sawDigit = alloca i64, align 8
  store i64 0, ptr %sawDigit, align 8
  %intPart = alloca double, align 8
  store double 0.000000e+00, ptr %intPart, align 8
  %frac = alloca double, align 8
  store double 0.000000e+00, ptr %frac, align 8
  %scale = alloca double, align 8
  store double 0.000000e+00, ptr %scale, align 8
  %mant = alloca double, align 8
  store double 0.000000e+00, ptr %mant, align 8
  %expNeg = alloca i64, align 8
  store i64 0, ptr %expNeg, align 8
  %sawExpDigit = alloca i64, align 8
  store i64 0, ptr %sawExpDigit, align 8
  %exp = alloca i64, align 8
  store i64 0, ptr %exp, align 8
  %p = alloca i64, align 8
  store i64 0, ptr %p, align 8
  %factor = alloca double, align 8
  store double 0.000000e+00, ptr %factor, align 8
  %1 = load i64, ptr %s, align 8
  %len_addr = sub i64 %1, 4
  %len_ptr = inttoptr i64 %len_addr to ptr
  %len_val = load i32, ptr %len_ptr, align 4
  %len_val_ext = zext i32 %len_val to i64
  store i64 %len_val_ext, ptr %len, align 8
  %2 = load i64, ptr %len, align 8
  %cmptmp = icmp eq i64 %2, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  ret i64 0

ifcont:                                           ; preds = %entry
  store i64 0, ptr %i, align 8
  store i64 0, ptr %neg, align 8
  %3 = load i64, ptr %s, align 8
  %index_addr = add i64 %3, 0
  %index_ptr = inttoptr i64 %index_addr to ptr
  %byte_val = load i8, ptr %index_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %cmptmp1 = icmp eq i64 %byte_val_ext, 45
  %zexttmp2 = zext i1 %cmptmp1 to i64
  %ifcond3 = icmp ne i64 %zexttmp2, 0
  br i1 %ifcond3, label %then4, label %else

then4:                                            ; preds = %ifcont
  store i64 1, ptr %neg, align 8
  store i64 1, ptr %i, align 8
  br label %ifcont5

else:                                             ; preds = %ifcont
  %4 = load i64, ptr %s, align 8
  %index_addr6 = add i64 %4, 0
  %index_ptr7 = inttoptr i64 %index_addr6 to ptr
  %byte_val8 = load i8, ptr %index_ptr7, align 1
  %byte_val_ext9 = zext i8 %byte_val8 to i64
  %cmptmp10 = icmp eq i64 %byte_val_ext9, 43
  %zexttmp11 = zext i1 %cmptmp10 to i64
  %ifcond12 = icmp ne i64 %zexttmp11, 0
  br i1 %ifcond12, label %then13, label %ifcont14

ifcont5:                                          ; preds = %ifcont14, %then4
  store i64 0, ptr %sawDigit, align 8
  store double 0.000000e+00, ptr %intPart, align 8
  br label %while_cond

then13:                                           ; preds = %else
  store i64 1, ptr %i, align 8
  br label %ifcont14

ifcont14:                                         ; preds = %then13, %else
  br label %ifcont5

while_cond:                                       ; preds = %while_body, %ifcont5
  %5 = load i64, ptr %i, align 8
  %6 = load i64, ptr %len, align 8
  %cmptmp15 = icmp slt i64 %5, %6
  %zexttmp16 = zext i1 %cmptmp15 to i64
  %7 = load i64, ptr %s, align 8
  %8 = load i64, ptr %i, align 8
  %index_addr17 = add i64 %7, %8
  %index_ptr18 = inttoptr i64 %index_addr17 to ptr
  %byte_val19 = load i8, ptr %index_ptr18, align 1
  %byte_val_ext20 = zext i8 %byte_val19 to i64
  %cmptmp21 = icmp sge i64 %byte_val_ext20, 48
  %zexttmp22 = zext i1 %cmptmp21 to i64
  %andtmp = and i64 %zexttmp16, %zexttmp22
  %9 = load i64, ptr %s, align 8
  %10 = load i64, ptr %i, align 8
  %index_addr23 = add i64 %9, %10
  %index_ptr24 = inttoptr i64 %index_addr23 to ptr
  %byte_val25 = load i8, ptr %index_ptr24, align 1
  %byte_val_ext26 = zext i8 %byte_val25 to i64
  %cmptmp27 = icmp sle i64 %byte_val_ext26, 57
  %zexttmp28 = zext i1 %cmptmp27 to i64
  %andtmp29 = and i64 %andtmp, %zexttmp28
  %whilecond = icmp ne i64 %andtmp29, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %11 = load double, ptr %intPart, align 8
  %fmultmp = fmul double %11, 1.000000e+01
  %12 = load i64, ptr %s, align 8
  %13 = load i64, ptr %i, align 8
  %index_addr30 = add i64 %12, %13
  %index_ptr31 = inttoptr i64 %index_addr30 to ptr
  %byte_val32 = load i8, ptr %index_ptr31, align 1
  %byte_val_ext33 = zext i8 %byte_val32 to i64
  %subtmp = sub i64 %byte_val_ext33, 48
  %int_trunc = trunc i64 %subtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  %cast_i2f = sitofp i64 %int_sext to double
  %cast_i2f_val = bitcast double %cast_i2f to i64
  %r_double = bitcast i64 %cast_i2f_val to double
  %faddtmp = fadd double %fmultmp, %r_double
  store double %faddtmp, ptr %intPart, align 8
  store i64 1, ptr %sawDigit, align 8
  %14 = load i64, ptr %i, align 8
  %addtmp = add i64 %14, 1
  %int_trunc34 = trunc i64 %addtmp to i32
  %int_sext35 = sext i32 %int_trunc34 to i64
  store i64 %int_sext35, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  store double 0.000000e+00, ptr %frac, align 8
  store double 1.000000e+00, ptr %scale, align 8
  %15 = load i64, ptr %i, align 8
  %16 = load i64, ptr %len, align 8
  %cmptmp36 = icmp slt i64 %15, %16
  %zexttmp37 = zext i1 %cmptmp36 to i64
  %17 = load i64, ptr %s, align 8
  %18 = load i64, ptr %i, align 8
  %index_addr38 = add i64 %17, %18
  %index_ptr39 = inttoptr i64 %index_addr38 to ptr
  %byte_val40 = load i8, ptr %index_ptr39, align 1
  %byte_val_ext41 = zext i8 %byte_val40 to i64
  %cmptmp42 = icmp eq i64 %byte_val_ext41, 46
  %zexttmp43 = zext i1 %cmptmp42 to i64
  %andtmp44 = and i64 %zexttmp37, %zexttmp43
  %ifcond45 = icmp ne i64 %andtmp44, 0
  br i1 %ifcond45, label %then46, label %ifcont47

then46:                                           ; preds = %while_exit
  %19 = load i64, ptr %i, align 8
  %addtmp48 = add i64 %19, 1
  %int_trunc49 = trunc i64 %addtmp48 to i32
  %int_sext50 = sext i32 %int_trunc49 to i64
  store i64 %int_sext50, ptr %i, align 8
  br label %while_cond51

ifcont47:                                         ; preds = %while_exit53, %while_exit
  %20 = load i64, ptr %sawDigit, align 8
  %nottmp = icmp eq i64 %20, 0
  %zexttmp85 = zext i1 %nottmp to i64
  %ifcond86 = icmp ne i64 %zexttmp85, 0
  br i1 %ifcond86, label %then87, label %ifcont88

while_cond51:                                     ; preds = %while_body52, %then46
  %21 = load i64, ptr %i, align 8
  %22 = load i64, ptr %len, align 8
  %cmptmp54 = icmp slt i64 %21, %22
  %zexttmp55 = zext i1 %cmptmp54 to i64
  %23 = load i64, ptr %s, align 8
  %24 = load i64, ptr %i, align 8
  %index_addr56 = add i64 %23, %24
  %index_ptr57 = inttoptr i64 %index_addr56 to ptr
  %byte_val58 = load i8, ptr %index_ptr57, align 1
  %byte_val_ext59 = zext i8 %byte_val58 to i64
  %cmptmp60 = icmp sge i64 %byte_val_ext59, 48
  %zexttmp61 = zext i1 %cmptmp60 to i64
  %andtmp62 = and i64 %zexttmp55, %zexttmp61
  %25 = load i64, ptr %s, align 8
  %26 = load i64, ptr %i, align 8
  %index_addr63 = add i64 %25, %26
  %index_ptr64 = inttoptr i64 %index_addr63 to ptr
  %byte_val65 = load i8, ptr %index_ptr64, align 1
  %byte_val_ext66 = zext i8 %byte_val65 to i64
  %cmptmp67 = icmp sle i64 %byte_val_ext66, 57
  %zexttmp68 = zext i1 %cmptmp67 to i64
  %andtmp69 = and i64 %andtmp62, %zexttmp68
  %whilecond70 = icmp ne i64 %andtmp69, 0
  br i1 %whilecond70, label %while_body52, label %while_exit53

while_body52:                                     ; preds = %while_cond51
  %27 = load double, ptr %scale, align 8
  %fdivtmp = fdiv double %27, 1.000000e+01
  store double %fdivtmp, ptr %scale, align 8
  %28 = load double, ptr %frac, align 8
  %29 = load i64, ptr %s, align 8
  %30 = load i64, ptr %i, align 8
  %index_addr71 = add i64 %29, %30
  %index_ptr72 = inttoptr i64 %index_addr71 to ptr
  %byte_val73 = load i8, ptr %index_ptr72, align 1
  %byte_val_ext74 = zext i8 %byte_val73 to i64
  %subtmp75 = sub i64 %byte_val_ext74, 48
  %int_trunc76 = trunc i64 %subtmp75 to i32
  %int_sext77 = sext i32 %int_trunc76 to i64
  %cast_i2f78 = sitofp i64 %int_sext77 to double
  %cast_i2f_val79 = bitcast double %cast_i2f78 to i64
  %31 = load double, ptr %scale, align 8
  %l_double = bitcast i64 %cast_i2f_val79 to double
  %fmultmp80 = fmul double %l_double, %31
  %faddtmp81 = fadd double %28, %fmultmp80
  store double %faddtmp81, ptr %frac, align 8
  store i64 1, ptr %sawDigit, align 8
  %32 = load i64, ptr %i, align 8
  %addtmp82 = add i64 %32, 1
  %int_trunc83 = trunc i64 %addtmp82 to i32
  %int_sext84 = sext i32 %int_trunc83 to i64
  store i64 %int_sext84, ptr %i, align 8
  br label %while_cond51

while_exit53:                                     ; preds = %while_cond51
  br label %ifcont47

then87:                                           ; preds = %ifcont47
  ret i64 0

ifcont88:                                         ; preds = %ifcont47
  %33 = load double, ptr %intPart, align 8
  %34 = load double, ptr %frac, align 8
  %faddtmp89 = fadd double %33, %34
  store double %faddtmp89, ptr %mant, align 8
  %35 = load i64, ptr %i, align 8
  %36 = load i64, ptr %len, align 8
  %cmptmp90 = icmp slt i64 %35, %36
  %zexttmp91 = zext i1 %cmptmp90 to i64
  %37 = load i64, ptr %s, align 8
  %38 = load i64, ptr %i, align 8
  %index_addr92 = add i64 %37, %38
  %index_ptr93 = inttoptr i64 %index_addr92 to ptr
  %byte_val94 = load i8, ptr %index_ptr93, align 1
  %byte_val_ext95 = zext i8 %byte_val94 to i64
  %cmptmp96 = icmp eq i64 %byte_val_ext95, 101
  %zexttmp97 = zext i1 %cmptmp96 to i64
  %39 = load i64, ptr %s, align 8
  %40 = load i64, ptr %i, align 8
  %index_addr98 = add i64 %39, %40
  %index_ptr99 = inttoptr i64 %index_addr98 to ptr
  %byte_val100 = load i8, ptr %index_ptr99, align 1
  %byte_val_ext101 = zext i8 %byte_val100 to i64
  %cmptmp102 = icmp eq i64 %byte_val_ext101, 69
  %zexttmp103 = zext i1 %cmptmp102 to i64
  %ortmp = or i64 %zexttmp97, %zexttmp103
  %andtmp104 = and i64 %zexttmp91, %ortmp
  %ifcond105 = icmp ne i64 %andtmp104, 0
  br i1 %ifcond105, label %then106, label %ifcont107

then106:                                          ; preds = %ifcont88
  %41 = load i64, ptr %i, align 8
  %addtmp108 = add i64 %41, 1
  %int_trunc109 = trunc i64 %addtmp108 to i32
  %int_sext110 = sext i32 %int_trunc109 to i64
  store i64 %int_sext110, ptr %i, align 8
  store i64 0, ptr %expNeg, align 8
  %42 = load i64, ptr %i, align 8
  %43 = load i64, ptr %len, align 8
  %cmptmp111 = icmp slt i64 %42, %43
  %zexttmp112 = zext i1 %cmptmp111 to i64
  %44 = load i64, ptr %s, align 8
  %45 = load i64, ptr %i, align 8
  %index_addr113 = add i64 %44, %45
  %index_ptr114 = inttoptr i64 %index_addr113 to ptr
  %byte_val115 = load i8, ptr %index_ptr114, align 1
  %byte_val_ext116 = zext i8 %byte_val115 to i64
  %cmptmp117 = icmp eq i64 %byte_val_ext116, 45
  %zexttmp118 = zext i1 %cmptmp117 to i64
  %andtmp119 = and i64 %zexttmp112, %zexttmp118
  %ifcond120 = icmp ne i64 %andtmp119, 0
  br i1 %ifcond120, label %then121, label %else122

ifcont107:                                        ; preds = %ifcont195, %ifcont88
  %46 = load i64, ptr %i, align 8
  %47 = load i64, ptr %len, align 8
  %cmptmp198 = icmp ne i64 %46, %47
  %zexttmp199 = zext i1 %cmptmp198 to i64
  %ifcond200 = icmp ne i64 %zexttmp199, 0
  br i1 %ifcond200, label %then201, label %ifcont202

then121:                                          ; preds = %then106
  store i64 1, ptr %expNeg, align 8
  %48 = load i64, ptr %i, align 8
  %addtmp124 = add i64 %48, 1
  %int_trunc125 = trunc i64 %addtmp124 to i32
  %int_sext126 = sext i32 %int_trunc125 to i64
  store i64 %int_sext126, ptr %i, align 8
  br label %ifcont123

else122:                                          ; preds = %then106
  %49 = load i64, ptr %i, align 8
  %50 = load i64, ptr %len, align 8
  %cmptmp127 = icmp slt i64 %49, %50
  %zexttmp128 = zext i1 %cmptmp127 to i64
  %51 = load i64, ptr %s, align 8
  %52 = load i64, ptr %i, align 8
  %index_addr129 = add i64 %51, %52
  %index_ptr130 = inttoptr i64 %index_addr129 to ptr
  %byte_val131 = load i8, ptr %index_ptr130, align 1
  %byte_val_ext132 = zext i8 %byte_val131 to i64
  %cmptmp133 = icmp eq i64 %byte_val_ext132, 43
  %zexttmp134 = zext i1 %cmptmp133 to i64
  %andtmp135 = and i64 %zexttmp128, %zexttmp134
  %ifcond136 = icmp ne i64 %andtmp135, 0
  br i1 %ifcond136, label %then137, label %ifcont138

ifcont123:                                        ; preds = %ifcont138, %then121
  store i64 0, ptr %sawExpDigit, align 8
  store i64 0, ptr %exp, align 8
  br label %while_cond142

then137:                                          ; preds = %else122
  %53 = load i64, ptr %i, align 8
  %addtmp139 = add i64 %53, 1
  %int_trunc140 = trunc i64 %addtmp139 to i32
  %int_sext141 = sext i32 %int_trunc140 to i64
  store i64 %int_sext141, ptr %i, align 8
  br label %ifcont138

ifcont138:                                        ; preds = %then137, %else122
  br label %ifcont123

while_cond142:                                    ; preds = %while_body143, %ifcont123
  %54 = load i64, ptr %i, align 8
  %55 = load i64, ptr %len, align 8
  %cmptmp145 = icmp slt i64 %54, %55
  %zexttmp146 = zext i1 %cmptmp145 to i64
  %56 = load i64, ptr %s, align 8
  %57 = load i64, ptr %i, align 8
  %index_addr147 = add i64 %56, %57
  %index_ptr148 = inttoptr i64 %index_addr147 to ptr
  %byte_val149 = load i8, ptr %index_ptr148, align 1
  %byte_val_ext150 = zext i8 %byte_val149 to i64
  %cmptmp151 = icmp sge i64 %byte_val_ext150, 48
  %zexttmp152 = zext i1 %cmptmp151 to i64
  %andtmp153 = and i64 %zexttmp146, %zexttmp152
  %58 = load i64, ptr %s, align 8
  %59 = load i64, ptr %i, align 8
  %index_addr154 = add i64 %58, %59
  %index_ptr155 = inttoptr i64 %index_addr154 to ptr
  %byte_val156 = load i8, ptr %index_ptr155, align 1
  %byte_val_ext157 = zext i8 %byte_val156 to i64
  %cmptmp158 = icmp sle i64 %byte_val_ext157, 57
  %zexttmp159 = zext i1 %cmptmp158 to i64
  %andtmp160 = and i64 %andtmp153, %zexttmp159
  %whilecond161 = icmp ne i64 %andtmp160, 0
  br i1 %whilecond161, label %while_body143, label %while_exit144

while_body143:                                    ; preds = %while_cond142
  %60 = load i64, ptr %exp, align 8
  %multmp = mul i64 %60, 10
  %int_trunc162 = trunc i64 %multmp to i32
  %int_sext163 = sext i32 %int_trunc162 to i64
  %61 = load i64, ptr %s, align 8
  %62 = load i64, ptr %i, align 8
  %index_addr164 = add i64 %61, %62
  %index_ptr165 = inttoptr i64 %index_addr164 to ptr
  %byte_val166 = load i8, ptr %index_ptr165, align 1
  %byte_val_ext167 = zext i8 %byte_val166 to i64
  %subtmp168 = sub i64 %byte_val_ext167, 48
  %int_trunc169 = trunc i64 %subtmp168 to i32
  %int_sext170 = sext i32 %int_trunc169 to i64
  %addtmp171 = add i64 %int_sext163, %int_sext170
  %int_trunc172 = trunc i64 %addtmp171 to i32
  %int_sext173 = sext i32 %int_trunc172 to i64
  store i64 %int_sext173, ptr %exp, align 8
  store i64 1, ptr %sawExpDigit, align 8
  %63 = load i64, ptr %i, align 8
  %addtmp174 = add i64 %63, 1
  %int_trunc175 = trunc i64 %addtmp174 to i32
  %int_sext176 = sext i32 %int_trunc175 to i64
  store i64 %int_sext176, ptr %i, align 8
  br label %while_cond142

while_exit144:                                    ; preds = %while_cond142
  %64 = load i64, ptr %sawExpDigit, align 8
  %nottmp177 = icmp eq i64 %64, 0
  %zexttmp178 = zext i1 %nottmp177 to i64
  %ifcond179 = icmp ne i64 %zexttmp178, 0
  br i1 %ifcond179, label %then180, label %ifcont181

then180:                                          ; preds = %while_exit144
  ret i64 0

ifcont181:                                        ; preds = %while_exit144
  store i64 0, ptr %p, align 8
  store double 1.000000e+00, ptr %factor, align 8
  br label %while_cond182

while_cond182:                                    ; preds = %while_body183, %ifcont181
  %65 = load i64, ptr %p, align 8
  %66 = load i64, ptr %exp, align 8
  %cmptmp185 = icmp slt i64 %65, %66
  %zexttmp186 = zext i1 %cmptmp185 to i64
  %whilecond187 = icmp ne i64 %zexttmp186, 0
  br i1 %whilecond187, label %while_body183, label %while_exit184

while_body183:                                    ; preds = %while_cond182
  %67 = load double, ptr %factor, align 8
  %fmultmp188 = fmul double %67, 1.000000e+01
  store double %fmultmp188, ptr %factor, align 8
  %68 = load i64, ptr %p, align 8
  %addtmp189 = add i64 %68, 1
  %int_trunc190 = trunc i64 %addtmp189 to i32
  %int_sext191 = sext i32 %int_trunc190 to i64
  store i64 %int_sext191, ptr %p, align 8
  br label %while_cond182

while_exit184:                                    ; preds = %while_cond182
  %69 = load i64, ptr %expNeg, align 8
  %ifcond192 = icmp ne i64 %69, 0
  br i1 %ifcond192, label %then193, label %else194

then193:                                          ; preds = %while_exit184
  %70 = load double, ptr %mant, align 8
  %71 = load double, ptr %factor, align 8
  %fdivtmp196 = fdiv double %70, %71
  store double %fdivtmp196, ptr %mant, align 8
  br label %ifcont195

else194:                                          ; preds = %while_exit184
  %72 = load double, ptr %mant, align 8
  %73 = load double, ptr %factor, align 8
  %fmultmp197 = fmul double %72, %73
  store double %fmultmp197, ptr %mant, align 8
  br label %ifcont195

ifcont195:                                        ; preds = %else194, %then193
  br label %ifcont107

then201:                                          ; preds = %ifcont107
  ret i64 0

ifcont202:                                        ; preds = %ifcont107
  %74 = load i64, ptr %neg, align 8
  %ifcond203 = icmp ne i64 %74, 0
  br i1 %ifcond203, label %then204, label %ifcont205

then204:                                          ; preds = %ifcont202
  %75 = load double, ptr %mant, align 8
  %fsubtmp = fsub double 0.000000e+00, %75
  store double %fsubtmp, ptr %mant, align 8
  br label %ifcont205

ifcont205:                                        ; preds = %then204, %ifcont202
  %76 = load double, ptr %mant, align 8
  %double_to_val = bitcast double %76 to i64
  %valopt_box = call i64 @nova_valopt_box(i64 %double_to_val)
  ret i64 %valopt_box
}

define void @string_delete(i64 %0) {
entry:
  ret void
}

define void @string_test_string_helpers() {
entry:
  %tmp_slot230 = alloca i64, align 8
  store i64 0, ptr %tmp_slot230, align 8
  %tmp_slot222 = alloca i64, align 8
  store i64 0, ptr %tmp_slot222, align 8
  %tmp_slot214 = alloca i64, align 8
  store i64 0, ptr %tmp_slot214, align 8
  %tmp_slot206 = alloca i64, align 8
  store i64 0, ptr %tmp_slot206, align 8
  %tmp_slot189 = alloca i64, align 8
  store i64 0, ptr %tmp_slot189, align 8
  %tmp_slot171 = alloca i64, align 8
  store i64 0, ptr %tmp_slot171, align 8
  %tmp_slot157 = alloca i64, align 8
  store i64 0, ptr %tmp_slot157, align 8
  %tmp_slot149 = alloca i64, align 8
  store i64 0, ptr %tmp_slot149, align 8
  %tmp_slot141 = alloca i64, align 8
  store i64 0, ptr %tmp_slot141, align 8
  %tmp_slot128 = alloca i64, align 8
  store i64 0, ptr %tmp_slot128, align 8
  %tmp_slot120 = alloca i64, align 8
  store i64 0, ptr %tmp_slot120, align 8
  %tmp_slot112 = alloca i64, align 8
  store i64 0, ptr %tmp_slot112, align 8
  %tmp_slot104 = alloca i64, align 8
  store i64 0, ptr %tmp_slot104, align 8
  %tmp_slot96 = alloca i64, align 8
  store i64 0, ptr %tmp_slot96, align 8
  %tmp_slot83 = alloca i64, align 8
  store i64 0, ptr %tmp_slot83, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %d1 = alloca double, align 8
  store double 0.000000e+00, ptr %d1, align 8
  %d2 = alloca double, align 8
  store double 0.000000e+00, ptr %d2, align 8
  %d3 = alloca double, align 8
  store double 0.000000e+00, ptr %d3, align 8
  %calltmp = call i64 @string_startsWith(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.6, i32 0, i32 2) to i64))
  %nottmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %nottmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [15 x i8] }>, ptr @str_literal.7, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  %calltmp1 = call i64 @string_startsWith(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.8, i32 0, i32 2) to i64))
  %ifcond2 = icmp ne i64 %calltmp1, 0
  br i1 %ifcond2, label %then3, label %ifcont4

then3:                                            ; preds = %ifcont
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [24 x i8] }>, ptr @str_literal.9, i32 0, i32 2))
  br label %ifcont4

ifcont4:                                          ; preds = %then3, %ifcont
  %calltmp5 = call i64 @string_endsWith(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.8, i32 0, i32 2) to i64))
  %nottmp6 = icmp eq i64 %calltmp5, 0
  %zexttmp7 = zext i1 %nottmp6 to i64
  %ifcond8 = icmp ne i64 %zexttmp7, 0
  br i1 %ifcond8, label %then9, label %ifcont10

then9:                                            ; preds = %ifcont4
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [13 x i8] }>, ptr @str_literal.10, i32 0, i32 2))
  br label %ifcont10

ifcont10:                                         ; preds = %then9, %ifcont4
  %calltmp11 = call i64 @string_endsWith(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.6, i32 0, i32 2) to i64))
  %ifcond12 = icmp ne i64 %calltmp11, 0
  br i1 %ifcond12, label %then13, label %ifcont14

then13:                                           ; preds = %ifcont10
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [22 x i8] }>, ptr @str_literal.11, i32 0, i32 2))
  br label %ifcont14

ifcont14:                                         ; preds = %then13, %ifcont10
  %calltmp15 = call i64 @string_contains(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.12, i32 0, i32 2) to i64))
  %nottmp16 = icmp eq i64 %calltmp15, 0
  %zexttmp17 = zext i1 %nottmp16 to i64
  %ifcond18 = icmp ne i64 %zexttmp17, 0
  br i1 %ifcond18, label %then19, label %ifcont20

then19:                                           ; preds = %ifcont14
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [13 x i8] }>, ptr @str_literal.13, i32 0, i32 2))
  br label %ifcont20

ifcont20:                                         ; preds = %then19, %ifcont14
  %calltmp21 = call i64 @string_contains(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.14, i32 0, i32 2) to i64))
  %ifcond22 = icmp ne i64 %calltmp21, 0
  br i1 %ifcond22, label %then23, label %ifcont24

then23:                                           ; preds = %ifcont20
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [22 x i8] }>, ptr @str_literal.15, i32 0, i32 2))
  br label %ifcont24

ifcont24:                                         ; preds = %then23, %ifcont20
  %calltmp25 = call i64 @string_indexOf(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.16, i32 0, i32 2) to i64))
  %cmptmp = icmp ne i64 %calltmp25, 1
  %zexttmp26 = zext i1 %cmptmp to i64
  %ifcond27 = icmp ne i64 %zexttmp26, 0
  br i1 %ifcond27, label %then28, label %ifcont29

then28:                                           ; preds = %ifcont24
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [12 x i8] }>, ptr @str_literal.17, i32 0, i32 2))
  br label %ifcont29

ifcont29:                                         ; preds = %then28, %ifcont24
  %calltmp30 = call i64 @string_indexOf(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.18, i32 0, i32 2) to i64))
  %cmptmp31 = icmp ne i64 %calltmp30, -1
  %zexttmp32 = zext i1 %cmptmp31 to i64
  %ifcond33 = icmp ne i64 %zexttmp32, 0
  br i1 %ifcond33, label %then34, label %ifcont35

then34:                                           ; preds = %ifcont29
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [21 x i8] }>, ptr @str_literal.19, i32 0, i32 2))
  br label %ifcont35

ifcont35:                                         ; preds = %then34, %ifcont29
  %calltmp36 = call i64 @string_eql(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64))
  %nottmp37 = icmp eq i64 %calltmp36, 0
  %zexttmp38 = zext i1 %nottmp37 to i64
  %ifcond39 = icmp ne i64 %zexttmp38, 0
  br i1 %ifcond39, label %then40, label %ifcont41

then40:                                           ; preds = %ifcont35
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.21, i32 0, i32 2))
  br label %ifcont41

ifcont41:                                         ; preds = %then40, %ifcont35
  %calltmp42 = call i64 @string_eql(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.22, i32 0, i32 2) to i64))
  %ifcond43 = icmp ne i64 %calltmp42, 0
  br i1 %ifcond43, label %then44, label %ifcont45

then44:                                           ; preds = %ifcont41
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [17 x i8] }>, ptr @str_literal.23, i32 0, i32 2))
  br label %ifcont45

ifcont45:                                         ; preds = %then44, %ifcont41
  %calltmp46 = call i64 @string_compare(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.22, i32 0, i32 2) to i64))
  %cmptmp47 = icmp ne i64 %calltmp46, -1
  %zexttmp48 = zext i1 %cmptmp47 to i64
  %ifcond49 = icmp ne i64 %zexttmp48, 0
  br i1 %ifcond49, label %then50, label %ifcont51

then50:                                           ; preds = %ifcont45
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [14 x i8] }>, ptr @str_literal.24, i32 0, i32 2))
  br label %ifcont51

ifcont51:                                         ; preds = %then50, %ifcont45
  %calltmp52 = call i64 @string_compare(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.22, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64))
  %cmptmp53 = icmp ne i64 %calltmp52, 1
  %zexttmp54 = zext i1 %cmptmp53 to i64
  %ifcond55 = icmp ne i64 %zexttmp54, 0
  br i1 %ifcond55, label %then56, label %ifcont57

then56:                                           ; preds = %ifcont51
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [14 x i8] }>, ptr @str_literal.25, i32 0, i32 2))
  br label %ifcont57

ifcont57:                                         ; preds = %then56, %ifcont51
  %calltmp58 = call i64 @string_compare(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64), i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64))
  %cmptmp59 = icmp ne i64 %calltmp58, 0
  %zexttmp60 = zext i1 %cmptmp59 to i64
  %ifcond61 = icmp ne i64 %zexttmp60, 0
  br i1 %ifcond61, label %then62, label %ifcont63

then62:                                           ; preds = %ifcont57
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [15 x i8] }>, ptr @str_literal.26, i32 0, i32 2))
  br label %ifcont63

ifcont63:                                         ; preds = %then62, %ifcont57
  %calltmp64 = call i64 @string_parseI64(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.27, i32 0, i32 2) to i64))
  %cmptmp65 = icmp ne i64 %calltmp64, 1234
  %zexttmp66 = zext i1 %cmptmp65 to i64
  %ifcond67 = icmp ne i64 %zexttmp66, 0
  br i1 %ifcond67, label %then68, label %ifcont69

then68:                                           ; preds = %ifcont63
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [22 x i8] }>, ptr @str_literal.28, i32 0, i32 2))
  br label %ifcont69

ifcont69:                                         ; preds = %then68, %ifcont63
  %calltmp70 = call i64 @string_parseI64(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.29, i32 0, i32 2) to i64))
  %cmptmp71 = icmp ne i64 %calltmp70, -56
  %zexttmp72 = zext i1 %cmptmp71 to i64
  %ifcond73 = icmp ne i64 %zexttmp72, 0
  br i1 %ifcond73, label %then74, label %ifcont75

then74:                                           ; preds = %ifcont69
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [22 x i8] }>, ptr @str_literal.30, i32 0, i32 2))
  br label %ifcont75

ifcont75:                                         ; preds = %then74, %ifcont69
  %calltmp76 = call i64 @string_parseLong(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.27, i32 0, i32 2) to i64))
  store i64 %calltmp76, ptr %tmp_slot, align 8
  %valopt_unbox = call i64 @nova_valopt_unbox(i64 %calltmp76)
  %is_not_null = icmp ne i64 %calltmp76, 0
  br i1 %is_not_null, label %nc_merge, label %nc_rhs

nc_rhs:                                           ; preds = %ifcont75
  br label %nc_merge

nc_merge:                                         ; preds = %nc_rhs, %ifcont75
  %nc_phi = phi i64 [ %valopt_unbox, %ifcont75 ], [ -1, %nc_rhs ]
  %cmptmp77 = icmp ne i64 %nc_phi, 1234
  %zexttmp78 = zext i1 %cmptmp77 to i64
  %ifcond79 = icmp ne i64 %zexttmp78, 0
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  br i1 %ifcond79, label %then80, label %ifcont81

then80:                                           ; preds = %nc_merge
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [17 x i8] }>, ptr @str_literal.31, i32 0, i32 2))
  br label %ifcont81

ifcont81:                                         ; preds = %then80, %nc_merge
  %calltmp82 = call i64 @string_parseLong(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.29, i32 0, i32 2) to i64))
  store i64 %calltmp82, ptr %tmp_slot83, align 8
  %valopt_unbox84 = call i64 @nova_valopt_unbox(i64 %calltmp82)
  %is_not_null87 = icmp ne i64 %calltmp82, 0
  br i1 %is_not_null87, label %nc_merge86, label %nc_rhs85

nc_rhs85:                                         ; preds = %ifcont81
  br label %nc_merge86

nc_merge86:                                       ; preds = %nc_rhs85, %ifcont81
  %nc_phi88 = phi i64 [ %valopt_unbox84, %ifcont81 ], [ 1, %nc_rhs85 ]
  %cmptmp89 = icmp ne i64 %nc_phi88, -56
  %zexttmp90 = zext i1 %cmptmp89 to i64
  %ifcond91 = icmp ne i64 %zexttmp90, 0
  %tmp_rel92 = load i64, ptr %tmp_slot83, align 8
  call void @nova_release(i64 %tmp_rel92, ptr null)
  store i64 0, ptr %tmp_slot83, align 8
  br i1 %ifcond91, label %then93, label %ifcont94

then93:                                           ; preds = %nc_merge86
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [18 x i8] }>, ptr @str_literal.32, i32 0, i32 2))
  br label %ifcont94

ifcont94:                                         ; preds = %then93, %nc_merge86
  %calltmp95 = call i64 @string_parseLong(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2) to i64))
  store i64 %calltmp95, ptr %tmp_slot96, align 8
  %cmptmp97 = icmp ne i64 %calltmp95, 0
  %zexttmp98 = zext i1 %cmptmp97 to i64
  %ifcond99 = icmp ne i64 %zexttmp98, 0
  %tmp_rel100 = load i64, ptr %tmp_slot96, align 8
  call void @nova_release(i64 %tmp_rel100, ptr null)
  store i64 0, ptr %tmp_slot96, align 8
  br i1 %ifcond99, label %then101, label %ifcont102

then101:                                          ; preds = %ifcont94
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [35 x i8] }>, ptr @str_literal.33, i32 0, i32 2))
  br label %ifcont102

ifcont102:                                        ; preds = %then101, %ifcont94
  %calltmp103 = call i64 @string_parseLong(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.34, i32 0, i32 2) to i64))
  store i64 %calltmp103, ptr %tmp_slot104, align 8
  %cmptmp105 = icmp ne i64 %calltmp103, 0
  %zexttmp106 = zext i1 %cmptmp105 to i64
  %ifcond107 = icmp ne i64 %zexttmp106, 0
  %tmp_rel108 = load i64, ptr %tmp_slot104, align 8
  call void @nova_release(i64 %tmp_rel108, ptr null)
  store i64 0, ptr %tmp_slot104, align 8
  br i1 %ifcond107, label %then109, label %ifcont110

then109:                                          ; preds = %ifcont102
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [46 x i8] }>, ptr @str_literal.35, i32 0, i32 2))
  br label %ifcont110

ifcont110:                                        ; preds = %then109, %ifcont102
  %calltmp111 = call i64 @string_parseLong(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.36, i32 0, i32 2) to i64))
  store i64 %calltmp111, ptr %tmp_slot112, align 8
  %cmptmp113 = icmp ne i64 %calltmp111, 0
  %zexttmp114 = zext i1 %cmptmp113 to i64
  %ifcond115 = icmp ne i64 %zexttmp114, 0
  %tmp_rel116 = load i64, ptr %tmp_slot112, align 8
  call void @nova_release(i64 %tmp_rel116, ptr null)
  store i64 0, ptr %tmp_slot112, align 8
  br i1 %ifcond115, label %then117, label %ifcont118

then117:                                          ; preds = %ifcont110
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [39 x i8] }>, ptr @str_literal.37, i32 0, i32 2))
  br label %ifcont118

ifcont118:                                        ; preds = %then117, %ifcont110
  %calltmp119 = call i64 @string_parseLong(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [20 x i8] }>, ptr @str_literal.38, i32 0, i32 2) to i64))
  store i64 %calltmp119, ptr %tmp_slot120, align 8
  %cmptmp121 = icmp ne i64 %calltmp119, 0
  %zexttmp122 = zext i1 %cmptmp121 to i64
  %ifcond123 = icmp ne i64 %zexttmp122, 0
  %tmp_rel124 = load i64, ptr %tmp_slot120, align 8
  call void @nova_release(i64 %tmp_rel124, ptr null)
  store i64 0, ptr %tmp_slot120, align 8
  br i1 %ifcond123, label %then125, label %ifcont126

then125:                                          ; preds = %ifcont118
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [38 x i8] }>, ptr @str_literal.39, i32 0, i32 2))
  br label %ifcont126

ifcont126:                                        ; preds = %then125, %ifcont118
  %calltmp127 = call i64 @string_parseInt(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.40, i32 0, i32 2) to i64))
  store i64 %calltmp127, ptr %tmp_slot128, align 8
  %valopt_unbox129 = call i64 @nova_valopt_unbox(i64 %calltmp127)
  %is_not_null132 = icmp ne i64 %calltmp127, 0
  br i1 %is_not_null132, label %nc_merge131, label %nc_rhs130

nc_rhs130:                                        ; preds = %ifcont126
  br label %nc_merge131

nc_merge131:                                      ; preds = %nc_rhs130, %ifcont126
  %nc_phi133 = phi i64 [ %valopt_unbox129, %ifcont126 ], [ -1, %nc_rhs130 ]
  %cmptmp134 = icmp ne i64 %nc_phi133, 42
  %zexttmp135 = zext i1 %cmptmp134 to i64
  %ifcond136 = icmp ne i64 %zexttmp135, 0
  %tmp_rel137 = load i64, ptr %tmp_slot128, align 8
  call void @nova_release(i64 %tmp_rel137, ptr null)
  store i64 0, ptr %tmp_slot128, align 8
  br i1 %ifcond136, label %then138, label %ifcont139

then138:                                          ; preds = %nc_merge131
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [16 x i8] }>, ptr @str_literal.41, i32 0, i32 2))
  br label %ifcont139

ifcont139:                                        ; preds = %then138, %nc_merge131
  %calltmp140 = call i64 @string_parseInt(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [10 x i8] }>, ptr @str_literal.42, i32 0, i32 2) to i64))
  store i64 %calltmp140, ptr %tmp_slot141, align 8
  %cmptmp142 = icmp ne i64 %calltmp140, 0
  %zexttmp143 = zext i1 %cmptmp142 to i64
  %ifcond144 = icmp ne i64 %zexttmp143, 0
  %tmp_rel145 = load i64, ptr %tmp_slot141, align 8
  call void @nova_release(i64 %tmp_rel145, ptr null)
  store i64 0, ptr %tmp_slot141, align 8
  br i1 %ifcond144, label %then146, label %ifcont147

then146:                                          ; preds = %ifcont139
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [45 x i8] }>, ptr @str_literal.43, i32 0, i32 2))
  br label %ifcont147

ifcont147:                                        ; preds = %then146, %ifcont139
  %calltmp148 = call i64 @string_parseInt(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.20, i32 0, i32 2) to i64))
  store i64 %calltmp148, ptr %tmp_slot149, align 8
  %cmptmp150 = icmp ne i64 %calltmp148, 0
  %zexttmp151 = zext i1 %cmptmp150 to i64
  %ifcond152 = icmp ne i64 %zexttmp151, 0
  %tmp_rel153 = load i64, ptr %tmp_slot149, align 8
  call void @nova_release(i64 %tmp_rel153, ptr null)
  store i64 0, ptr %tmp_slot149, align 8
  br i1 %ifcond152, label %then154, label %ifcont155

then154:                                          ; preds = %ifcont147
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [40 x i8] }>, ptr @str_literal.44, i32 0, i32 2))
  br label %ifcont155

ifcont155:                                        ; preds = %then154, %ifcont147
  %calltmp156 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.45, i32 0, i32 2) to i64))
  store i64 %calltmp156, ptr %tmp_slot157, align 8
  %valopt_unbox158 = call i64 @nova_valopt_unbox(i64 %calltmp156)
  %is_not_null161 = icmp ne i64 %calltmp156, 0
  br i1 %is_not_null161, label %nc_merge160, label %nc_rhs159

nc_rhs159:                                        ; preds = %ifcont155
  br label %nc_merge160

nc_merge160:                                      ; preds = %nc_rhs159, %ifcont155
  %nc_phi162 = phi i64 [ %valopt_unbox158, %ifcont155 ], [ 0, %nc_rhs159 ]
  %l_double = bitcast i64 %nc_phi162 to double
  %fsubtmp = fsub double %l_double, 1.000000e+03
  store double %fsubtmp, ptr %d1, align 8
  %tmp_rel163 = load i64, ptr %tmp_slot157, align 8
  call void @nova_release(i64 %tmp_rel163, ptr null)
  store i64 0, ptr %tmp_slot157, align 8
  %0 = load double, ptr %d1, align 8
  %fcmptmp = fcmp ogt double %0, 1.000000e-04
  %zexttmp164 = zext i1 %fcmptmp to i64
  %1 = load double, ptr %d1, align 8
  %fcmptmp165 = fcmp olt double %1, -1.000000e-04
  %zexttmp166 = zext i1 %fcmptmp165 to i64
  %ortmp = or i64 %zexttmp164, %zexttmp166
  %ifcond167 = icmp ne i64 %ortmp, 0
  br i1 %ifcond167, label %then168, label %ifcont169

then168:                                          ; preds = %nc_merge160
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [25 x i8] }>, ptr @str_literal.46, i32 0, i32 2))
  br label %ifcont169

ifcont169:                                        ; preds = %then168, %nc_merge160
  %calltmp170 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.47, i32 0, i32 2) to i64))
  store i64 %calltmp170, ptr %tmp_slot171, align 8
  %valopt_unbox172 = call i64 @nova_valopt_unbox(i64 %calltmp170)
  %is_not_null175 = icmp ne i64 %calltmp170, 0
  br i1 %is_not_null175, label %nc_merge174, label %nc_rhs173

nc_rhs173:                                        ; preds = %ifcont169
  br label %nc_merge174

nc_merge174:                                      ; preds = %nc_rhs173, %ifcont169
  %nc_phi176 = phi i64 [ %valopt_unbox172, %ifcont169 ], [ 0, %nc_rhs173 ]
  %l_double177 = bitcast i64 %nc_phi176 to double
  %fsubtmp178 = fsub double %l_double177, 2.500000e+00
  store double %fsubtmp178, ptr %d2, align 8
  %tmp_rel179 = load i64, ptr %tmp_slot171, align 8
  call void @nova_release(i64 %tmp_rel179, ptr null)
  store i64 0, ptr %tmp_slot171, align 8
  %2 = load double, ptr %d2, align 8
  %fcmptmp180 = fcmp ogt double %2, 1.000000e-04
  %zexttmp181 = zext i1 %fcmptmp180 to i64
  %3 = load double, ptr %d2, align 8
  %fcmptmp182 = fcmp olt double %3, -1.000000e-04
  %zexttmp183 = zext i1 %fcmptmp182 to i64
  %ortmp184 = or i64 %zexttmp181, %zexttmp183
  %ifcond185 = icmp ne i64 %ortmp184, 0
  br i1 %ifcond185, label %then186, label %ifcont187

then186:                                          ; preds = %nc_merge174
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [21 x i8] }>, ptr @str_literal.48, i32 0, i32 2))
  br label %ifcont187

ifcont187:                                        ; preds = %then186, %nc_merge174
  %calltmp188 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [6 x i8] }>, ptr @str_literal.49, i32 0, i32 2) to i64))
  store i64 %calltmp188, ptr %tmp_slot189, align 8
  %valopt_unbox190 = call i64 @nova_valopt_unbox(i64 %calltmp188)
  %is_not_null193 = icmp ne i64 %calltmp188, 0
  br i1 %is_not_null193, label %nc_merge192, label %nc_rhs191

nc_rhs191:                                        ; preds = %ifcont187
  br label %nc_merge192

nc_merge192:                                      ; preds = %nc_rhs191, %ifcont187
  %nc_phi194 = phi i64 [ %valopt_unbox190, %ifcont187 ], [ 0, %nc_rhs191 ]
  %l_double195 = bitcast i64 %nc_phi194 to double
  %faddtmp = fadd double %l_double195, 1.500000e+02
  store double %faddtmp, ptr %d3, align 8
  %tmp_rel196 = load i64, ptr %tmp_slot189, align 8
  call void @nova_release(i64 %tmp_rel196, ptr null)
  store i64 0, ptr %tmp_slot189, align 8
  %4 = load double, ptr %d3, align 8
  %fcmptmp197 = fcmp ogt double %4, 1.000000e-04
  %zexttmp198 = zext i1 %fcmptmp197 to i64
  %5 = load double, ptr %d3, align 8
  %fcmptmp199 = fcmp olt double %5, -1.000000e-04
  %zexttmp200 = zext i1 %fcmptmp199 to i64
  %ortmp201 = or i64 %zexttmp198, %zexttmp200
  %ifcond202 = icmp ne i64 %ortmp201, 0
  br i1 %ifcond202, label %then203, label %ifcont204

then203:                                          ; preds = %nc_merge192
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [24 x i8] }>, ptr @str_literal.50, i32 0, i32 2))
  br label %ifcont204

ifcont204:                                        ; preds = %then203, %nc_merge192
  %calltmp205 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2) to i64))
  store i64 %calltmp205, ptr %tmp_slot206, align 8
  %cmptmp207 = icmp ne i64 %calltmp205, 0
  %zexttmp208 = zext i1 %cmptmp207 to i64
  %ifcond209 = icmp ne i64 %zexttmp208, 0
  %tmp_rel210 = load i64, ptr %tmp_slot206, align 8
  call void @nova_release(i64 %tmp_rel210, ptr null)
  store i64 0, ptr %tmp_slot206, align 8
  br i1 %ifcond209, label %then211, label %ifcont212

then211:                                          ; preds = %ifcont204
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [37 x i8] }>, ptr @str_literal.51, i32 0, i32 2))
  br label %ifcont212

ifcont212:                                        ; preds = %then211, %ifcont204
  %calltmp213 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.52, i32 0, i32 2) to i64))
  store i64 %calltmp213, ptr %tmp_slot214, align 8
  %cmptmp215 = icmp ne i64 %calltmp213, 0
  %zexttmp216 = zext i1 %cmptmp215 to i64
  %ifcond217 = icmp ne i64 %zexttmp216, 0
  %tmp_rel218 = load i64, ptr %tmp_slot214, align 8
  call void @nova_release(i64 %tmp_rel218, ptr null)
  store i64 0, ptr %tmp_slot214, align 8
  br i1 %ifcond217, label %then219, label %ifcont220

then219:                                          ; preds = %ifcont212
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [42 x i8] }>, ptr @str_literal.53, i32 0, i32 2))
  br label %ifcont220

ifcont220:                                        ; preds = %then219, %ifcont212
  %calltmp221 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.54, i32 0, i32 2) to i64))
  store i64 %calltmp221, ptr %tmp_slot222, align 8
  %cmptmp223 = icmp ne i64 %calltmp221, 0
  %zexttmp224 = zext i1 %cmptmp223 to i64
  %ifcond225 = icmp ne i64 %zexttmp224, 0
  %tmp_rel226 = load i64, ptr %tmp_slot222, align 8
  call void @nova_release(i64 %tmp_rel226, ptr null)
  store i64 0, ptr %tmp_slot222, align 8
  br i1 %ifcond225, label %then227, label %ifcont228

then227:                                          ; preds = %ifcont220
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [44 x i8] }>, ptr @str_literal.55, i32 0, i32 2))
  br label %ifcont228

ifcont228:                                        ; preds = %then227, %ifcont220
  %calltmp229 = call i64 @string_parseDouble(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.56, i32 0, i32 2) to i64))
  store i64 %calltmp229, ptr %tmp_slot230, align 8
  %cmptmp231 = icmp ne i64 %calltmp229, 0
  %zexttmp232 = zext i1 %cmptmp231 to i64
  %ifcond233 = icmp ne i64 %zexttmp232, 0
  %tmp_rel234 = load i64, ptr %tmp_slot230, align 8
  call void @nova_release(i64 %tmp_rel234, ptr null)
  store i64 0, ptr %tmp_slot230, align 8
  br i1 %ifcond233, label %then235, label %ifcont236

then235:                                          ; preds = %ifcont228
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [48 x i8] }>, ptr @str_literal.57, i32 0, i32 2))
  br label %ifcont236

ifcont236:                                        ; preds = %then235, %ifcont228
  ret void
}

define void @assert_fail(i64 %0) {
entry:
  %msg = alloca i64, align 8
  store i64 %0, ptr %msg, align 8
  %1 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %1 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  ret void
}

define void @assert_isTrue(i64 %0) {
entry:
  %val = alloca i64, align 8
  store i64 %0, ptr %val, align 8
  %1 = load i64, ptr %val, align 8
  %nottmp = icmp eq i64 %1, 0
  %zexttmp = zext i1 %nottmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [24 x i8] }>, ptr @str_literal.58, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_isFalse(i64 %0) {
entry:
  %val = alloca i64, align 8
  store i64 %0, ptr %val, align 8
  %1 = load i64, ptr %val, align 8
  %ifcond = icmp ne i64 %1, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [24 x i8] }>, ptr @str_literal.59, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_equalInt(i64 %0, i64 %1) {
entry:
  %tmp_slot5 = alloca i64, align 8
  store i64 0, ptr %tmp_slot5, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %actual = alloca i64, align 8
  store i64 %0, ptr %actual, align 8
  %expected = alloca i64, align 8
  store i64 %1, ptr %expected, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %actual, align 8
  %3 = load i64, ptr %expected, align 8
  %cmptmp = icmp ne i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %expected, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %4)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.60, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [6 x i8] }>, ptr @str_literal.61, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %actual, align 8
  %i64_str3 = call i64 @nova_i64_to_string(i64 %5)
  %concat_tmp4 = call i64 @string_concat(i64 %concat_tmp1, i64 %i64_str3)
  call void @nova_release(i64 %i64_str3, ptr null)
  store i64 %concat_tmp4, ptr %tmp_slot5, align 8
  store i64 %concat_tmp4, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel6 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel6, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_notEqualInt(i64 %0, i64 %1) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %actual = alloca i64, align 8
  store i64 %0, ptr %actual, align 8
  %expected = alloca i64, align 8
  store i64 %1, ptr %expected, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %actual, align 8
  %3 = load i64, ptr %expected, align 8
  %cmptmp = icmp eq i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %actual, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %4)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [37 x i8] }>, ptr @str_literal.62, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  store i64 %concat_tmp, ptr %msg, align 8
  %5 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %5 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_equalStr(i64 %0, i64 %1) {
entry:
  %tmp_slot6 = alloca i64, align 8
  store i64 0, ptr %tmp_slot6, align 8
  %tmp_slot4 = alloca i64, align 8
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %actual = alloca i64, align 8
  store i64 %0, ptr %actual, align 8
  %expected = alloca i64, align 8
  store i64 %1, ptr %expected, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %actual, align 8
  %3 = load i64, ptr %expected, align 8
  %calltmp = call i64 @string_eql(i64 %2, i64 %3)
  %nottmp = icmp eq i64 %calltmp, 0
  %zexttmp = zext i1 %nottmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %expected, align 8
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [10 x i8] }>, ptr @str_literal.63, i32 0, i32 2) to i64), i64 %4)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.64, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %actual, align 8
  %concat_tmp3 = call i64 @string_concat(i64 %concat_tmp1, i64 %5)
  store i64 %concat_tmp3, ptr %tmp_slot4, align 8
  %concat_tmp5 = call i64 @string_concat(i64 %concat_tmp3, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.65, i32 0, i32 2) to i64))
  store i64 %concat_tmp5, ptr %tmp_slot6, align 8
  store i64 %concat_tmp5, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot4, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_rel7 = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel7, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel8 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel8, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_notEqualStr(i64 %0, i64 %1) {
entry:
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %actual = alloca i64, align 8
  store i64 %0, ptr %actual, align 8
  %expected = alloca i64, align 8
  store i64 %1, ptr %expected, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %actual, align 8
  %3 = load i64, ptr %expected, align 8
  %calltmp = call i64 @string_eql(i64 %2, i64 %3)
  %ifcond = icmp ne i64 %calltmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %actual, align 8
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [39 x i8] }>, ptr @str_literal.66, i32 0, i32 2) to i64), i64 %4)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.65, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  store i64 %concat_tmp1, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %5 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %5 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_contains(i64 %0, i64 %1) {
entry:
  %tmp_slot6 = alloca i64, align 8
  store i64 0, ptr %tmp_slot6, align 8
  %tmp_slot4 = alloca i64, align 8
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %haystack = alloca i64, align 8
  store i64 %0, ptr %haystack, align 8
  %needle = alloca i64, align 8
  store i64 %1, ptr %needle, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %haystack, align 8
  %3 = load i64, ptr %needle, align 8
  %calltmp = call i64 @string_indexOf(i64 %2, i64 %3)
  %cmptmp = icmp eq i64 %calltmp, -1
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %haystack, align 8
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [10 x i8] }>, ptr @str_literal.63, i32 0, i32 2) to i64), i64 %4)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [14 x i8] }>, ptr @str_literal.67, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %needle, align 8
  %concat_tmp3 = call i64 @string_concat(i64 %concat_tmp1, i64 %5)
  store i64 %concat_tmp3, ptr %tmp_slot4, align 8
  %concat_tmp5 = call i64 @string_concat(i64 %concat_tmp3, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.65, i32 0, i32 2) to i64))
  store i64 %concat_tmp5, ptr %tmp_slot6, align 8
  store i64 %concat_tmp5, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot4, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_rel7 = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel7, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel8 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel8, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_notZero(i64 %0) {
entry:
  %val = alloca i64, align 8
  store i64 %0, ptr %val, align 8
  %1 = load i64, ptr %val, align 8
  %cmptmp = icmp eq i64 %1, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  call void @nova_test_fail(ptr getelementptr inbounds nuw (<{ i32, i32, [30 x i8] }>, ptr @str_literal.68, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_zero(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %val = alloca i64, align 8
  store i64 %0, ptr %val, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %1 = load i64, ptr %val, align 8
  %cmptmp = icmp ne i64 %1, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %2 = load i64, ptr %val, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %2)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [16 x i8] }>, ptr @str_literal.69, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  store i64 %concat_tmp, ptr %msg, align 8
  %3 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %3 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_gt(i64 %0, i64 %1) {
entry:
  %tmp_slot5 = alloca i64, align 8
  store i64 0, ptr %tmp_slot5, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %a, align 8
  %3 = load i64, ptr %b, align 8
  %cmptmp = icmp sle i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %a, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %4)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.60, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.70, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %b, align 8
  %i64_str3 = call i64 @nova_i64_to_string(i64 %5)
  %concat_tmp4 = call i64 @string_concat(i64 %concat_tmp1, i64 %i64_str3)
  call void @nova_release(i64 %i64_str3, ptr null)
  store i64 %concat_tmp4, ptr %tmp_slot5, align 8
  store i64 %concat_tmp4, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel6 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel6, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_gte(i64 %0, i64 %1) {
entry:
  %tmp_slot5 = alloca i64, align 8
  store i64 0, ptr %tmp_slot5, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %a, align 8
  %3 = load i64, ptr %b, align 8
  %cmptmp = icmp slt i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %a, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %4)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.60, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.71, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %b, align 8
  %i64_str3 = call i64 @nova_i64_to_string(i64 %5)
  %concat_tmp4 = call i64 @string_concat(i64 %concat_tmp1, i64 %i64_str3)
  call void @nova_release(i64 %i64_str3, ptr null)
  store i64 %concat_tmp4, ptr %tmp_slot5, align 8
  store i64 %concat_tmp4, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel6 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel6, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_lt(i64 %0, i64 %1) {
entry:
  %tmp_slot5 = alloca i64, align 8
  store i64 0, ptr %tmp_slot5, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %a, align 8
  %3 = load i64, ptr %b, align 8
  %cmptmp = icmp sge i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %a, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %4)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.60, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [3 x i8] }>, ptr @str_literal.72, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %b, align 8
  %i64_str3 = call i64 @nova_i64_to_string(i64 %5)
  %concat_tmp4 = call i64 @string_concat(i64 %concat_tmp1, i64 %i64_str3)
  call void @nova_release(i64 %i64_str3, ptr null)
  store i64 %concat_tmp4, ptr %tmp_slot5, align 8
  store i64 %concat_tmp4, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel6 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel6, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_lte(i64 %0, i64 %1) {
entry:
  %tmp_slot5 = alloca i64, align 8
  store i64 0, ptr %tmp_slot5, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 8
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %2 = load i64, ptr %a, align 8
  %3 = load i64, ptr %b, align 8
  %cmptmp = icmp sgt i64 %2, %3
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %4 = load i64, ptr %a, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %4)
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.60, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp, ptr %tmp_slot, align 8
  %concat_tmp1 = call i64 @string_concat(i64 %concat_tmp, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.73, i32 0, i32 2) to i64))
  store i64 %concat_tmp1, ptr %tmp_slot2, align 8
  %5 = load i64, ptr %b, align 8
  %i64_str3 = call i64 @nova_i64_to_string(i64 %5)
  %concat_tmp4 = call i64 @string_concat(i64 %concat_tmp1, i64 %i64_str3)
  call void @nova_release(i64 %i64_str3, ptr null)
  store i64 %concat_tmp4, ptr %tmp_slot5, align 8
  store i64 %concat_tmp4, ptr %msg, align 8
  %tmp_rel = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_rel6 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel6, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  %6 = load i64, ptr %msg, align 8
  %arg_ptr_cast = inttoptr i64 %6 to ptr
  call void @nova_test_fail(ptr %arg_ptr_cast)
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %then, %entry
  ret void
}

define void @assert_test_assert_mechanics() {
entry:
  call void @assert_isTrue(i64 1)
  call void @assert_isFalse(i64 0)
  call void @assert_equalInt(i64 42, i64 42)
  call void @assert_notEqualInt(i64 42, i64 43)
  call void @assert_gt(i64 10, i64 5)
  call void @assert_gte(i64 10, i64 10)
  call void @assert_lt(i64 5, i64 10)
  call void @assert_lte(i64 10, i64 10)
  ret void
}

define void @collections_string_builder_test_string_builder() {
entry:
  %tmp_slot1 = alloca i64, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %sb = alloca i64, align 8
  store i64 0, ptr %sb, align 8
  %res = alloca i64, align 8
  store i64 0, ptr %res, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @StringBuilder_init(i64 %alloc_tmp)
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  store i64 %alloc_tmp, ptr %sb, align 8
  %0 = load i64, ptr %sb, align 8
  call void @StringBuilder_append(i64 %0, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.5, i32 0, i32 2) to i64))
  %1 = load i64, ptr %sb, align 8
  call void @StringBuilder_append(i64 %1, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.74, i32 0, i32 2) to i64))
  %2 = load i64, ptr %sb, align 8
  call void @StringBuilder_append(i64 %2, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.14, i32 0, i32 2) to i64))
  %3 = load i64, ptr %sb, align 8
  %calltmp = call i64 @StringBuilder_toString(i64 %3)
  store i64 %calltmp, ptr %tmp_slot1, align 8
  store i64 %calltmp, ptr %res, align 8
  %4 = load i64, ptr %res, align 8
  %eql_tmp = call i64 @string_eql(i64 %4, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [11 x i8] }>, ptr @str_literal.75, i32 0, i32 2) to i64))
  call void @assert_isTrue(i64 %eql_tmp)
  %var_rel_load = load i64, ptr %res, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  %var_rel_load2 = load i64, ptr %sb, align 8
  call void @nova_release(i64 %var_rel_load2, ptr @__destruct_StringBuilder)
  ret void
}

define i64 @fetch(i64 %0) {
entry:
  %tmp_slot17 = alloca i64, align 8
  store i64 0, ptr %tmp_slot17, align 8
  %tmp_slot10 = alloca i64, align 8
  store i64 0, ptr %tmp_slot10, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %k = alloca i64, align 8
  store i64 %0, ptr %k, align 8
  %1 = load i64, ptr %k, align 8
  %eql_tmp = call i64 @string_eql(i64 %1, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [7 x i8] }>, ptr @str_literal.80, i32 0, i32 2) to i64))
  %ifcond = icmp ne i64 %eql_tmp, 0
  br i1 %ifcond, label %then, label %ifcont

then:                                             ; preds = %entry
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  %tag_ptr = inttoptr i64 %alloc_tmp to ptr
  store i64 0, ptr %tag_ptr, align 8
  %2 = load i64, ptr %k, align 8
  call void @nova_retain(i64 %2)
  %payload_addr = add i64 %alloc_tmp, 8
  %payload_ptr = inttoptr i64 %payload_addr to ptr
  store i64 %2, ptr %payload_ptr, align 8
  store i64 %alloc_tmp, ptr %tmp_slot, align 8
  %alloc_tmp1 = call i64 @nova_bytes_alloc(i64 16)
  call void @nova_retain(i64 %alloc_tmp)
  %eu_tag_ptr = inttoptr i64 %alloc_tmp1 to ptr
  store i64 1, ptr %eu_tag_ptr, align 8
  %eu_pay_addr = add i64 %alloc_tmp1, 8
  %eu_pay_ptr = inttoptr i64 %eu_pay_addr to ptr
  store i64 %alloc_tmp, ptr %eu_pay_ptr, align 8
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr @__destruct_LookupError)
  store i64 0, ptr %tmp_slot, align 8
  ret i64 %alloc_tmp1

ifcont:                                           ; preds = %entry
  %3 = load i64, ptr %k, align 8
  %eql_tmp2 = call i64 @string_eql(i64 %3, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.81, i32 0, i32 2) to i64))
  %ifcond3 = icmp ne i64 %eql_tmp2, 0
  br i1 %ifcond3, label %then4, label %ifcont5

then4:                                            ; preds = %ifcont
  %alloc_tmp6 = call i64 @nova_bytes_alloc(i64 16)
  %tag_ptr7 = inttoptr i64 %alloc_tmp6 to ptr
  store i64 1, ptr %tag_ptr7, align 8
  %payload_addr8 = add i64 %alloc_tmp6, 8
  %payload_ptr9 = inttoptr i64 %payload_addr8 to ptr
  store i64 500, ptr %payload_ptr9, align 8
  store i64 %alloc_tmp6, ptr %tmp_slot10, align 8
  %alloc_tmp11 = call i64 @nova_bytes_alloc(i64 16)
  call void @nova_retain(i64 %alloc_tmp6)
  %eu_tag_ptr12 = inttoptr i64 %alloc_tmp11 to ptr
  store i64 1, ptr %eu_tag_ptr12, align 8
  %eu_pay_addr13 = add i64 %alloc_tmp11, 8
  %eu_pay_ptr14 = inttoptr i64 %eu_pay_addr13 to ptr
  store i64 %alloc_tmp6, ptr %eu_pay_ptr14, align 8
  %tmp_rel15 = load i64, ptr %tmp_slot10, align 8
  call void @nova_release(i64 %tmp_rel15, ptr @__destruct_LookupError)
  store i64 0, ptr %tmp_slot10, align 8
  ret i64 %alloc_tmp11

ifcont5:                                          ; preds = %ifcont
  %alloc_tmp16 = call i64 @nova_bytes_alloc(i64 16)
  call void @StringBuilder_init(i64 %alloc_tmp16)
  call void @StringBuilder_append(i64 %alloc_tmp16, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.82, i32 0, i32 2) to i64))
  %4 = load i64, ptr %k, align 8
  call void @StringBuilder_append(i64 %alloc_tmp16, i64 %4)
  %final_str = call i64 @StringBuilder_toString(i64 %alloc_tmp16)
  call void @StringBuilder_delete(i64 %alloc_tmp16)
  call void @nova_release(i64 %alloc_tmp16, ptr null)
  store i64 %final_str, ptr %tmp_slot17, align 8
  %alloc_tmp18 = call i64 @nova_bytes_alloc(i64 16)
  call void @nova_retain(i64 %final_str)
  %eu_tag_ptr19 = inttoptr i64 %alloc_tmp18 to ptr
  store i64 0, ptr %eu_tag_ptr19, align 8
  %eu_pay_addr20 = add i64 %alloc_tmp18, 8
  %eu_pay_ptr21 = inttoptr i64 %eu_pay_addr20 to ptr
  store i64 %final_str, ptr %eu_pay_ptr21, align 8
  %tmp_rel22 = load i64, ptr %tmp_slot17, align 8
  call void @nova_release(i64 %tmp_rel22, ptr null)
  store i64 0, ptr %tmp_slot17, align 8
  ret i64 %alloc_tmp18
}

define void @test_ok_passes_through() {
entry:
  %tmp_slot4 = alloca i64, align 8
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_slot3 = alloca i64, align 8
  store i64 0, ptr %tmp_slot3, align 8
  %e = alloca i64, align 8
  store i64 0, ptr %e, align 8
  %tmp_slot1 = alloca i64, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %calltmp = call i64 @fetch(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.123, i32 0, i32 2) to i64))
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %c_tag_ptr = inttoptr i64 %calltmp to ptr
  %c_tag = load i64, ptr %c_tag_ptr, align 8
  %c_is_err = icmp eq i64 %c_tag, 1
  %c_pay_addr = add i64 %calltmp, 8
  %c_pay_ptr = inttoptr i64 %c_pay_addr to ptr
  br i1 %c_is_err, label %catch_err, label %catch_ok

catch_err:                                        ; preds = %entry
  %c_err = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_err)
  store i64 %c_err, ptr %e, align 8
  %0 = load i64, ptr %e, align 8
  %calltmp2 = call i64 @LookupError_message(i64 %0)
  store i64 %calltmp2, ptr %tmp_slot3, align 8
  store i64 %calltmp2, ptr %tmp_slot1, align 8
  br label %catch_done

catch_ok:                                         ; preds = %entry
  %c_pay = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_pay)
  store i64 %c_pay, ptr %tmp_slot1, align 8
  br label %catch_done

catch_done:                                       ; preds = %catch_ok, %catch_err
  %catch_val = load i64, ptr %tmp_slot1, align 8
  store i64 %catch_val, ptr %tmp_slot4, align 8
  call void @assert_equalStr(i64 %catch_val, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [14 x i8] }>, ptr @str_literal.83, i32 0, i32 2) to i64))
  %tmp_rel = load i64, ptr %tmp_slot4, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_rel5 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel5, ptr @__destruct_ErrUnion_lpstring_LookupError_rp)
  store i64 0, ptr %tmp_slot, align 8
  %var_rel_load = load i64, ptr %e, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_LookupError)
  ret void
}

define void @test_first_variant_dispatches() {
entry:
  %tmp_slot4 = alloca i64, align 8
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_slot3 = alloca i64, align 8
  store i64 0, ptr %tmp_slot3, align 8
  %e = alloca i64, align 8
  store i64 0, ptr %e, align 8
  %tmp_slot1 = alloca i64, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %calltmp = call i64 @fetch(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [7 x i8] }>, ptr @str_literal.80, i32 0, i32 2) to i64))
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %c_tag_ptr = inttoptr i64 %calltmp to ptr
  %c_tag = load i64, ptr %c_tag_ptr, align 8
  %c_is_err = icmp eq i64 %c_tag, 1
  %c_pay_addr = add i64 %calltmp, 8
  %c_pay_ptr = inttoptr i64 %c_pay_addr to ptr
  br i1 %c_is_err, label %catch_err, label %catch_ok

catch_err:                                        ; preds = %entry
  %c_err = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_err)
  store i64 %c_err, ptr %e, align 8
  %0 = load i64, ptr %e, align 8
  %calltmp2 = call i64 @LookupError_message(i64 %0)
  store i64 %calltmp2, ptr %tmp_slot3, align 8
  store i64 %calltmp2, ptr %tmp_slot1, align 8
  br label %catch_done

catch_ok:                                         ; preds = %entry
  %c_pay = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_pay)
  store i64 %c_pay, ptr %tmp_slot1, align 8
  br label %catch_done

catch_done:                                       ; preds = %catch_ok, %catch_err
  %catch_val = load i64, ptr %tmp_slot1, align 8
  store i64 %catch_val, ptr %tmp_slot4, align 8
  call void @assert_equalStr(i64 %catch_val, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [18 x i8] }>, ptr @str_literal.84, i32 0, i32 2) to i64))
  %tmp_rel = load i64, ptr %tmp_slot4, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_rel5 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel5, ptr @__destruct_ErrUnion_lpstring_LookupError_rp)
  store i64 0, ptr %tmp_slot, align 8
  %var_rel_load = load i64, ptr %e, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_LookupError)
  ret void
}

define void @test_second_variant_dispatches() {
entry:
  %tmp_slot4 = alloca i64, align 8
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_slot3 = alloca i64, align 8
  store i64 0, ptr %tmp_slot3, align 8
  %e = alloca i64, align 8
  store i64 0, ptr %e, align 8
  %tmp_slot1 = alloca i64, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %calltmp = call i64 @fetch(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.81, i32 0, i32 2) to i64))
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %c_tag_ptr = inttoptr i64 %calltmp to ptr
  %c_tag = load i64, ptr %c_tag_ptr, align 8
  %c_is_err = icmp eq i64 %c_tag, 1
  %c_pay_addr = add i64 %calltmp, 8
  %c_pay_ptr = inttoptr i64 %c_pay_addr to ptr
  br i1 %c_is_err, label %catch_err, label %catch_ok

catch_err:                                        ; preds = %entry
  %c_err = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_err)
  store i64 %c_err, ptr %e, align 8
  %0 = load i64, ptr %e, align 8
  %calltmp2 = call i64 @LookupError_message(i64 %0)
  store i64 %calltmp2, ptr %tmp_slot3, align 8
  store i64 %calltmp2, ptr %tmp_slot1, align 8
  br label %catch_done

catch_ok:                                         ; preds = %entry
  %c_pay = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_pay)
  store i64 %c_pay, ptr %tmp_slot1, align 8
  br label %catch_done

catch_done:                                       ; preds = %catch_ok, %catch_err
  %catch_val = load i64, ptr %tmp_slot1, align 8
  store i64 %catch_val, ptr %tmp_slot4, align 8
  call void @assert_equalStr(i64 %catch_val, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [21 x i8] }>, ptr @str_literal.85, i32 0, i32 2) to i64))
  %tmp_rel = load i64, ptr %tmp_slot4, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_rel5 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel5, ptr @__destruct_ErrUnion_lpstring_LookupError_rp)
  store i64 0, ptr %tmp_slot, align 8
  %var_rel_load = load i64, ptr %e, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_LookupError)
  ret void
}

define i64 @fetchTwice(i64 %0) {
entry:
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot1 = alloca i64, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %k = alloca i64, align 8
  store i64 %0, ptr %k, align 8
  %a = alloca i64, align 8
  store i64 0, ptr %a, align 8
  %1 = load i64, ptr %k, align 8
  %calltmp = call i64 @fetch(i64 %1)
  store i64 %calltmp, ptr %tmp_slot, align 8
  %try_tag_ptr = inttoptr i64 %calltmp to ptr
  %try_tag = load i64, ptr %try_tag_ptr, align 8
  %try_is_err = icmp eq i64 %try_tag, 1
  br i1 %try_is_err, label %try_propagate, label %try_ok

try_propagate:                                    ; preds = %entry
  ret i64 %calltmp

try_ok:                                           ; preds = %entry
  %try_pay_addr = add i64 %calltmp, 8
  %try_pay_ptr = inttoptr i64 %try_pay_addr to ptr
  %try_pay = load i64, ptr %try_pay_ptr, align 8
  call void @nova_retain(i64 %try_pay)
  store i64 %try_pay, ptr %tmp_slot1, align 8
  store i64 %try_pay, ptr %a, align 8
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr @__destruct_ErrUnion_lpstring_LookupError_rp)
  store i64 0, ptr %tmp_slot, align 8
  %2 = load i64, ptr %a, align 8
  %concat_tmp = call i64 @string_concat(i64 %2, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [1 x i8] }>, ptr @str_literal.86, i32 0, i32 2) to i64))
  store i64 %concat_tmp, ptr %tmp_slot2, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 16)
  call void @nova_retain(i64 %concat_tmp)
  %eu_tag_ptr = inttoptr i64 %alloc_tmp to ptr
  store i64 0, ptr %eu_tag_ptr, align 8
  %eu_pay_addr = add i64 %alloc_tmp, 8
  %eu_pay_ptr = inttoptr i64 %eu_pay_addr to ptr
  store i64 %concat_tmp, ptr %eu_pay_ptr, align 8
  %tmp_rel3 = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel3, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %var_rel_load = load i64, ptr %a, align 8
  call void @nova_release(i64 %var_rel_load, ptr null)
  ret i64 %alloc_tmp
}

define void @test_try_propagates_exception() {
entry:
  %tmp_slot22 = alloca i64, align 8
  store i64 0, ptr %tmp_slot22, align 8
  %tmp_slot19 = alloca i64, align 8
  store i64 0, ptr %tmp_slot19, align 8
  %tmp_slot8 = alloca i64, align 8
  store i64 0, ptr %tmp_slot8, align 8
  %tmp_slot7 = alloca i64, align 8
  store i64 0, ptr %tmp_slot7, align 8
  %tmp_slot4 = alloca i64, align 8
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_slot3 = alloca i64, align 8
  store i64 0, ptr %tmp_slot3, align 8
  %e = alloca i64, align 8
  store i64 0, ptr %e, align 8
  %tmp_slot1 = alloca i64, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %calltmp = call i64 @fetchTwice(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [2 x i8] }>, ptr @str_literal.124, i32 0, i32 2) to i64))
  store i64 %calltmp, ptr %tmp_slot, align 8
  store i64 0, ptr %tmp_slot1, align 8
  %c_tag_ptr = inttoptr i64 %calltmp to ptr
  %c_tag = load i64, ptr %c_tag_ptr, align 8
  %c_is_err = icmp eq i64 %c_tag, 1
  %c_pay_addr = add i64 %calltmp, 8
  %c_pay_ptr = inttoptr i64 %c_pay_addr to ptr
  br i1 %c_is_err, label %catch_err, label %catch_ok

catch_err:                                        ; preds = %entry
  %c_err = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_err)
  store i64 %c_err, ptr %e, align 8
  %0 = load i64, ptr %e, align 8
  %calltmp2 = call i64 @LookupError_message(i64 %0)
  store i64 %calltmp2, ptr %tmp_slot3, align 8
  store i64 %calltmp2, ptr %tmp_slot1, align 8
  br label %catch_done

catch_ok:                                         ; preds = %entry
  %c_pay = load i64, ptr %c_pay_ptr, align 8
  call void @nova_retain(i64 %c_pay)
  store i64 %c_pay, ptr %tmp_slot1, align 8
  br label %catch_done

catch_done:                                       ; preds = %catch_ok, %catch_err
  %catch_val = load i64, ptr %tmp_slot1, align 8
  store i64 %catch_val, ptr %tmp_slot4, align 8
  call void @assert_equalStr(i64 %catch_val, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [12 x i8] }>, ptr @str_literal.87, i32 0, i32 2) to i64))
  %tmp_rel = load i64, ptr %tmp_slot4, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot4, align 8
  %tmp_rel5 = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel5, ptr @__destruct_ErrUnion_lpstring_LookupError_rp)
  store i64 0, ptr %tmp_slot, align 8
  %calltmp6 = call i64 @fetchTwice(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [7 x i8] }>, ptr @str_literal.80, i32 0, i32 2) to i64))
  store i64 %calltmp6, ptr %tmp_slot7, align 8
  store i64 0, ptr %tmp_slot8, align 8
  %c_tag_ptr9 = inttoptr i64 %calltmp6 to ptr
  %c_tag10 = load i64, ptr %c_tag_ptr9, align 8
  %c_is_err11 = icmp eq i64 %c_tag10, 1
  %c_pay_addr12 = add i64 %calltmp6, 8
  %c_pay_ptr13 = inttoptr i64 %c_pay_addr12 to ptr
  br i1 %c_is_err11, label %catch_err14, label %catch_ok15

catch_err14:                                      ; preds = %catch_done
  %c_err17 = load i64, ptr %c_pay_ptr13, align 8
  call void @nova_retain(i64 %c_err17)
  store i64 %c_err17, ptr %e, align 8
  %1 = load i64, ptr %e, align 8
  %calltmp18 = call i64 @LookupError_message(i64 %1)
  store i64 %calltmp18, ptr %tmp_slot19, align 8
  store i64 %calltmp18, ptr %tmp_slot8, align 8
  br label %catch_done16

catch_ok15:                                       ; preds = %catch_done
  %c_pay20 = load i64, ptr %c_pay_ptr13, align 8
  call void @nova_retain(i64 %c_pay20)
  store i64 %c_pay20, ptr %tmp_slot8, align 8
  br label %catch_done16

catch_done16:                                     ; preds = %catch_ok15, %catch_err14
  %catch_val21 = load i64, ptr %tmp_slot8, align 8
  store i64 %catch_val21, ptr %tmp_slot22, align 8
  call void @assert_equalStr(i64 %catch_val21, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [18 x i8] }>, ptr @str_literal.84, i32 0, i32 2) to i64))
  %tmp_rel23 = load i64, ptr %tmp_slot22, align 8
  call void @nova_release(i64 %tmp_rel23, ptr null)
  store i64 0, ptr %tmp_slot22, align 8
  %tmp_rel24 = load i64, ptr %tmp_slot7, align 8
  call void @nova_release(i64 %tmp_rel24, ptr @__destruct_ErrUnion_lpstring_LookupError_rp)
  store i64 0, ptr %tmp_slot7, align 8
  %var_rel_load = load i64, ptr %e, align 8
  call void @nova_release(i64 %var_rel_load, ptr @__destruct_LookupError)
  ret void
}

define i64 @__nova_main() {
entry:
  %tmp_slot173 = alloca i64, align 8
  store i64 0, ptr %tmp_slot173, align 8
  %tmp_slot171 = alloca i64, align 8
  store i64 0, ptr %tmp_slot171, align 8
  %tmp_slot168 = alloca i64, align 8
  store i64 0, ptr %tmp_slot168, align 8
  %tmp_slot166 = alloca i64, align 8
  store i64 0, ptr %tmp_slot166, align 8
  %tmp_slot163 = alloca i64, align 8
  store i64 0, ptr %tmp_slot163, align 8
  %tmp_slot161 = alloca i64, align 8
  store i64 0, ptr %tmp_slot161, align 8
  %tmp_slot153 = alloca i64, align 8
  store i64 0, ptr %tmp_slot153, align 8
  %tmp_slot151 = alloca i64, align 8
  store i64 0, ptr %tmp_slot151, align 8
  %tmp_slot131 = alloca i64, align 8
  store i64 0, ptr %tmp_slot131, align 8
  %tmp_slot129 = alloca i64, align 8
  store i64 0, ptr %tmp_slot129, align 8
  %tmp_slot109 = alloca i64, align 8
  store i64 0, ptr %tmp_slot109, align 8
  %tmp_slot107 = alloca i64, align 8
  store i64 0, ptr %tmp_slot107, align 8
  %tmp_slot87 = alloca i64, align 8
  store i64 0, ptr %tmp_slot87, align 8
  %tmp_slot85 = alloca i64, align 8
  store i64 0, ptr %tmp_slot85, align 8
  %tmp_slot65 = alloca i64, align 8
  store i64 0, ptr %tmp_slot65, align 8
  %tmp_slot63 = alloca i64, align 8
  store i64 0, ptr %tmp_slot63, align 8
  %tmp_slot43 = alloca i64, align 8
  store i64 0, ptr %tmp_slot43, align 8
  %tmp_slot41 = alloca i64, align 8
  store i64 0, ptr %tmp_slot41, align 8
  %tmp_slot21 = alloca i64, align 8
  store i64 0, ptr %tmp_slot21, align 8
  %tmp_slot19 = alloca i64, align 8
  store i64 0, ptr %tmp_slot19, align 8
  %tmp_slot2 = alloca i64, align 8
  store i64 0, ptr %tmp_slot2, align 8
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %__test_total = alloca i64, align 8
  store i64 0, ptr %__test_total, align 8
  %__test_passed = alloca i64, align 8
  store i64 0, ptr %__test_passed, align 8
  %__test_failed = alloca i64, align 8
  store i64 0, ptr %__test_failed, align 8
  %msg = alloca i64, align 8
  store i64 0, ptr %msg, align 8
  %"msg$1" = alloca i64, align 8
  store i64 0, ptr %"msg$1", align 8
  %"msg$2" = alloca i64, align 8
  store i64 0, ptr %"msg$2", align 8
  %"msg$3" = alloca i64, align 8
  store i64 0, ptr %"msg$3", align 8
  %"msg$4" = alloca i64, align 8
  store i64 0, ptr %"msg$4", align 8
  %"msg$5" = alloca i64, align 8
  store i64 0, ptr %"msg$5", align 8
  %"msg$6" = alloca i64, align 8
  store i64 0, ptr %"msg$6", align 8
  %"msg$7" = alloca i64, align 8
  store i64 0, ptr %"msg$7", align 8
  %heap_alloc = call ptr @malloc(i64 16777216)
  %heap_alloc_int = ptrtoint ptr %heap_alloc to i64
  store i64 %heap_alloc_int, ptr @heap_ptr, align 8
  store i64 8, ptr %__test_total, align 8
  store i64 0, ptr %__test_passed, align 8
  store i64 0, ptr %__test_failed, align 8
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [20 x i8] }>, ptr @str_literal.88, i32 0, i32 2))
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2))
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.89, i32 0, i32 2))
  call void @collections_list_test_list()
  %calltmp = call i32 @nova_test_did_fail()
  %ret_sext = sext i32 %calltmp to i64
  %cmptmp = icmp eq i64 %ret_sext, 0
  %zexttmp = zext i1 %cmptmp to i64
  %ifcond = icmp ne i64 %zexttmp, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [17 x i8] }>, ptr @str_literal.90, i32 0, i32 2))
  %0 = load i64, ptr %__test_passed, align 8
  %addtmp = add i64 %0, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %__test_passed, align 8
  br label %ifcont

else:                                             ; preds = %entry
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [17 x i8] }>, ptr @str_literal.91, i32 0, i32 2))
  %calltmp1 = call ptr @nova_test_fail_message()
  %ret_ptr_int = ptrtoint ptr %calltmp1 to i64
  store i64 %ret_ptr_int, ptr %tmp_slot, align 8
  store i64 %ret_ptr_int, ptr %msg, align 8
  %1 = load i64, ptr %msg, align 8
  %concat_tmp = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %1)
  store i64 %concat_tmp, ptr %tmp_slot2, align 8
  %puts_ptr = inttoptr i64 %concat_tmp to ptr
  call void @nova_log_string(ptr %puts_ptr)
  %tmp_rel = load i64, ptr %tmp_slot2, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot2, align 8
  %2 = load i64, ptr %__test_failed, align 8
  %addtmp3 = add i64 %2, 1
  %int_trunc4 = trunc i64 %addtmp3 to i32
  %int_sext5 = sext i32 %int_trunc4 to i64
  store i64 %int_sext5, ptr %__test_failed, align 8
  %blk_rel_load = load i64, ptr %msg, align 8
  call void @nova_release(i64 %blk_rel_load, ptr null)
  store i64 0, ptr %msg, align 8
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [19 x i8] }>, ptr @str_literal.93, i32 0, i32 2))
  call void @string_test_string_helpers()
  %calltmp6 = call i32 @nova_test_did_fail()
  %ret_sext7 = sext i32 %calltmp6 to i64
  %cmptmp8 = icmp eq i64 %ret_sext7, 0
  %zexttmp9 = zext i1 %cmptmp8 to i64
  %ifcond10 = icmp ne i64 %zexttmp9, 0
  br i1 %ifcond10, label %then11, label %else12

then11:                                           ; preds = %ifcont
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [27 x i8] }>, ptr @str_literal.94, i32 0, i32 2))
  %3 = load i64, ptr %__test_passed, align 8
  %addtmp14 = add i64 %3, 1
  %int_trunc15 = trunc i64 %addtmp14 to i32
  %int_sext16 = sext i32 %int_trunc15 to i64
  store i64 %int_sext16, ptr %__test_passed, align 8
  br label %ifcont13

else12:                                           ; preds = %ifcont
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [27 x i8] }>, ptr @str_literal.95, i32 0, i32 2))
  %calltmp17 = call ptr @nova_test_fail_message()
  %ret_ptr_int18 = ptrtoint ptr %calltmp17 to i64
  store i64 %ret_ptr_int18, ptr %tmp_slot19, align 8
  store i64 %ret_ptr_int18, ptr %"msg$1", align 8
  %4 = load i64, ptr %"msg$1", align 8
  %concat_tmp20 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %4)
  store i64 %concat_tmp20, ptr %tmp_slot21, align 8
  %puts_ptr22 = inttoptr i64 %concat_tmp20 to ptr
  call void @nova_log_string(ptr %puts_ptr22)
  %tmp_rel23 = load i64, ptr %tmp_slot21, align 8
  call void @nova_release(i64 %tmp_rel23, ptr null)
  store i64 0, ptr %tmp_slot21, align 8
  %5 = load i64, ptr %__test_failed, align 8
  %addtmp24 = add i64 %5, 1
  %int_trunc25 = trunc i64 %addtmp24 to i32
  %int_sext26 = sext i32 %int_trunc25 to i64
  store i64 %int_sext26, ptr %__test_failed, align 8
  %blk_rel_load27 = load i64, ptr %"msg$1", align 8
  call void @nova_release(i64 %blk_rel_load27, ptr null)
  store i64 0, ptr %"msg$1", align 8
  br label %ifcont13

ifcont13:                                         ; preds = %else12, %then11
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [21 x i8] }>, ptr @str_literal.96, i32 0, i32 2))
  call void @assert_test_assert_mechanics()
  %calltmp28 = call i32 @nova_test_did_fail()
  %ret_sext29 = sext i32 %calltmp28 to i64
  %cmptmp30 = icmp eq i64 %ret_sext29, 0
  %zexttmp31 = zext i1 %cmptmp30 to i64
  %ifcond32 = icmp ne i64 %zexttmp31, 0
  br i1 %ifcond32, label %then33, label %else34

then33:                                           ; preds = %ifcont13
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [29 x i8] }>, ptr @str_literal.97, i32 0, i32 2))
  %6 = load i64, ptr %__test_passed, align 8
  %addtmp36 = add i64 %6, 1
  %int_trunc37 = trunc i64 %addtmp36 to i32
  %int_sext38 = sext i32 %int_trunc37 to i64
  store i64 %int_sext38, ptr %__test_passed, align 8
  br label %ifcont35

else34:                                           ; preds = %ifcont13
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [29 x i8] }>, ptr @str_literal.98, i32 0, i32 2))
  %calltmp39 = call ptr @nova_test_fail_message()
  %ret_ptr_int40 = ptrtoint ptr %calltmp39 to i64
  store i64 %ret_ptr_int40, ptr %tmp_slot41, align 8
  store i64 %ret_ptr_int40, ptr %"msg$2", align 8
  %7 = load i64, ptr %"msg$2", align 8
  %concat_tmp42 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %7)
  store i64 %concat_tmp42, ptr %tmp_slot43, align 8
  %puts_ptr44 = inttoptr i64 %concat_tmp42 to ptr
  call void @nova_log_string(ptr %puts_ptr44)
  %tmp_rel45 = load i64, ptr %tmp_slot43, align 8
  call void @nova_release(i64 %tmp_rel45, ptr null)
  store i64 0, ptr %tmp_slot43, align 8
  %8 = load i64, ptr %__test_failed, align 8
  %addtmp46 = add i64 %8, 1
  %int_trunc47 = trunc i64 %addtmp46 to i32
  %int_sext48 = sext i32 %int_trunc47 to i64
  store i64 %int_sext48, ptr %__test_failed, align 8
  %blk_rel_load49 = load i64, ptr %"msg$2", align 8
  call void @nova_release(i64 %blk_rel_load49, ptr null)
  store i64 0, ptr %"msg$2", align 8
  br label %ifcont35

ifcont35:                                         ; preds = %else34, %then33
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [19 x i8] }>, ptr @str_literal.99, i32 0, i32 2))
  call void @collections_string_builder_test_string_builder()
  %calltmp50 = call i32 @nova_test_did_fail()
  %ret_sext51 = sext i32 %calltmp50 to i64
  %cmptmp52 = icmp eq i64 %ret_sext51, 0
  %zexttmp53 = zext i1 %cmptmp52 to i64
  %ifcond54 = icmp ne i64 %zexttmp53, 0
  br i1 %ifcond54, label %then55, label %else56

then55:                                           ; preds = %ifcont35
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [27 x i8] }>, ptr @str_literal.100, i32 0, i32 2))
  %9 = load i64, ptr %__test_passed, align 8
  %addtmp58 = add i64 %9, 1
  %int_trunc59 = trunc i64 %addtmp58 to i32
  %int_sext60 = sext i32 %int_trunc59 to i64
  store i64 %int_sext60, ptr %__test_passed, align 8
  br label %ifcont57

else56:                                           ; preds = %ifcont35
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [27 x i8] }>, ptr @str_literal.101, i32 0, i32 2))
  %calltmp61 = call ptr @nova_test_fail_message()
  %ret_ptr_int62 = ptrtoint ptr %calltmp61 to i64
  store i64 %ret_ptr_int62, ptr %tmp_slot63, align 8
  store i64 %ret_ptr_int62, ptr %"msg$3", align 8
  %10 = load i64, ptr %"msg$3", align 8
  %concat_tmp64 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %10)
  store i64 %concat_tmp64, ptr %tmp_slot65, align 8
  %puts_ptr66 = inttoptr i64 %concat_tmp64 to ptr
  call void @nova_log_string(ptr %puts_ptr66)
  %tmp_rel67 = load i64, ptr %tmp_slot65, align 8
  call void @nova_release(i64 %tmp_rel67, ptr null)
  store i64 0, ptr %tmp_slot65, align 8
  %11 = load i64, ptr %__test_failed, align 8
  %addtmp68 = add i64 %11, 1
  %int_trunc69 = trunc i64 %addtmp68 to i32
  %int_sext70 = sext i32 %int_trunc69 to i64
  store i64 %int_sext70, ptr %__test_failed, align 8
  %blk_rel_load71 = load i64, ptr %"msg$3", align 8
  call void @nova_release(i64 %blk_rel_load71, ptr null)
  store i64 0, ptr %"msg$3", align 8
  br label %ifcont57

ifcont57:                                         ; preds = %else56, %then55
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [22 x i8] }>, ptr @str_literal.102, i32 0, i32 2))
  call void @test_ok_passes_through()
  %calltmp72 = call i32 @nova_test_did_fail()
  %ret_sext73 = sext i32 %calltmp72 to i64
  %cmptmp74 = icmp eq i64 %ret_sext73, 0
  %zexttmp75 = zext i1 %cmptmp74 to i64
  %ifcond76 = icmp ne i64 %zexttmp75, 0
  br i1 %ifcond76, label %then77, label %else78

then77:                                           ; preds = %ifcont57
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [30 x i8] }>, ptr @str_literal.103, i32 0, i32 2))
  %12 = load i64, ptr %__test_passed, align 8
  %addtmp80 = add i64 %12, 1
  %int_trunc81 = trunc i64 %addtmp80 to i32
  %int_sext82 = sext i32 %int_trunc81 to i64
  store i64 %int_sext82, ptr %__test_passed, align 8
  br label %ifcont79

else78:                                           ; preds = %ifcont57
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [30 x i8] }>, ptr @str_literal.104, i32 0, i32 2))
  %calltmp83 = call ptr @nova_test_fail_message()
  %ret_ptr_int84 = ptrtoint ptr %calltmp83 to i64
  store i64 %ret_ptr_int84, ptr %tmp_slot85, align 8
  store i64 %ret_ptr_int84, ptr %"msg$4", align 8
  %13 = load i64, ptr %"msg$4", align 8
  %concat_tmp86 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %13)
  store i64 %concat_tmp86, ptr %tmp_slot87, align 8
  %puts_ptr88 = inttoptr i64 %concat_tmp86 to ptr
  call void @nova_log_string(ptr %puts_ptr88)
  %tmp_rel89 = load i64, ptr %tmp_slot87, align 8
  call void @nova_release(i64 %tmp_rel89, ptr null)
  store i64 0, ptr %tmp_slot87, align 8
  %14 = load i64, ptr %__test_failed, align 8
  %addtmp90 = add i64 %14, 1
  %int_trunc91 = trunc i64 %addtmp90 to i32
  %int_sext92 = sext i32 %int_trunc91 to i64
  store i64 %int_sext92, ptr %__test_failed, align 8
  %blk_rel_load93 = load i64, ptr %"msg$4", align 8
  call void @nova_release(i64 %blk_rel_load93, ptr null)
  store i64 0, ptr %"msg$4", align 8
  br label %ifcont79

ifcont79:                                         ; preds = %else78, %then77
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [29 x i8] }>, ptr @str_literal.105, i32 0, i32 2))
  call void @test_first_variant_dispatches()
  %calltmp94 = call i32 @nova_test_did_fail()
  %ret_sext95 = sext i32 %calltmp94 to i64
  %cmptmp96 = icmp eq i64 %ret_sext95, 0
  %zexttmp97 = zext i1 %cmptmp96 to i64
  %ifcond98 = icmp ne i64 %zexttmp97, 0
  br i1 %ifcond98, label %then99, label %else100

then99:                                           ; preds = %ifcont79
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [37 x i8] }>, ptr @str_literal.106, i32 0, i32 2))
  %15 = load i64, ptr %__test_passed, align 8
  %addtmp102 = add i64 %15, 1
  %int_trunc103 = trunc i64 %addtmp102 to i32
  %int_sext104 = sext i32 %int_trunc103 to i64
  store i64 %int_sext104, ptr %__test_passed, align 8
  br label %ifcont101

else100:                                          ; preds = %ifcont79
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [37 x i8] }>, ptr @str_literal.107, i32 0, i32 2))
  %calltmp105 = call ptr @nova_test_fail_message()
  %ret_ptr_int106 = ptrtoint ptr %calltmp105 to i64
  store i64 %ret_ptr_int106, ptr %tmp_slot107, align 8
  store i64 %ret_ptr_int106, ptr %"msg$5", align 8
  %16 = load i64, ptr %"msg$5", align 8
  %concat_tmp108 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %16)
  store i64 %concat_tmp108, ptr %tmp_slot109, align 8
  %puts_ptr110 = inttoptr i64 %concat_tmp108 to ptr
  call void @nova_log_string(ptr %puts_ptr110)
  %tmp_rel111 = load i64, ptr %tmp_slot109, align 8
  call void @nova_release(i64 %tmp_rel111, ptr null)
  store i64 0, ptr %tmp_slot109, align 8
  %17 = load i64, ptr %__test_failed, align 8
  %addtmp112 = add i64 %17, 1
  %int_trunc113 = trunc i64 %addtmp112 to i32
  %int_sext114 = sext i32 %int_trunc113 to i64
  store i64 %int_sext114, ptr %__test_failed, align 8
  %blk_rel_load115 = load i64, ptr %"msg$5", align 8
  call void @nova_release(i64 %blk_rel_load115, ptr null)
  store i64 0, ptr %"msg$5", align 8
  br label %ifcont101

ifcont101:                                        ; preds = %else100, %then99
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [30 x i8] }>, ptr @str_literal.108, i32 0, i32 2))
  call void @test_second_variant_dispatches()
  %calltmp116 = call i32 @nova_test_did_fail()
  %ret_sext117 = sext i32 %calltmp116 to i64
  %cmptmp118 = icmp eq i64 %ret_sext117, 0
  %zexttmp119 = zext i1 %cmptmp118 to i64
  %ifcond120 = icmp ne i64 %zexttmp119, 0
  br i1 %ifcond120, label %then121, label %else122

then121:                                          ; preds = %ifcont101
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [38 x i8] }>, ptr @str_literal.109, i32 0, i32 2))
  %18 = load i64, ptr %__test_passed, align 8
  %addtmp124 = add i64 %18, 1
  %int_trunc125 = trunc i64 %addtmp124 to i32
  %int_sext126 = sext i32 %int_trunc125 to i64
  store i64 %int_sext126, ptr %__test_passed, align 8
  br label %ifcont123

else122:                                          ; preds = %ifcont101
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [38 x i8] }>, ptr @str_literal.110, i32 0, i32 2))
  %calltmp127 = call ptr @nova_test_fail_message()
  %ret_ptr_int128 = ptrtoint ptr %calltmp127 to i64
  store i64 %ret_ptr_int128, ptr %tmp_slot129, align 8
  store i64 %ret_ptr_int128, ptr %"msg$6", align 8
  %19 = load i64, ptr %"msg$6", align 8
  %concat_tmp130 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %19)
  store i64 %concat_tmp130, ptr %tmp_slot131, align 8
  %puts_ptr132 = inttoptr i64 %concat_tmp130 to ptr
  call void @nova_log_string(ptr %puts_ptr132)
  %tmp_rel133 = load i64, ptr %tmp_slot131, align 8
  call void @nova_release(i64 %tmp_rel133, ptr null)
  store i64 0, ptr %tmp_slot131, align 8
  %20 = load i64, ptr %__test_failed, align 8
  %addtmp134 = add i64 %20, 1
  %int_trunc135 = trunc i64 %addtmp134 to i32
  %int_sext136 = sext i32 %int_trunc135 to i64
  store i64 %int_sext136, ptr %__test_failed, align 8
  %blk_rel_load137 = load i64, ptr %"msg$6", align 8
  call void @nova_release(i64 %blk_rel_load137, ptr null)
  store i64 0, ptr %"msg$6", align 8
  br label %ifcont123

ifcont123:                                        ; preds = %else122, %then121
  call void @nova_test_reset()
  call void @nova_test_begin(ptr getelementptr inbounds nuw (<{ i32, i32, [29 x i8] }>, ptr @str_literal.111, i32 0, i32 2))
  call void @test_try_propagates_exception()
  %calltmp138 = call i32 @nova_test_did_fail()
  %ret_sext139 = sext i32 %calltmp138 to i64
  %cmptmp140 = icmp eq i64 %ret_sext139, 0
  %zexttmp141 = zext i1 %cmptmp140 to i64
  %ifcond142 = icmp ne i64 %zexttmp141, 0
  br i1 %ifcond142, label %then143, label %else144

then143:                                          ; preds = %ifcont123
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [37 x i8] }>, ptr @str_literal.112, i32 0, i32 2))
  %21 = load i64, ptr %__test_passed, align 8
  %addtmp146 = add i64 %21, 1
  %int_trunc147 = trunc i64 %addtmp146 to i32
  %int_sext148 = sext i32 %int_trunc147 to i64
  store i64 %int_sext148, ptr %__test_passed, align 8
  br label %ifcont145

else144:                                          ; preds = %ifcont123
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [37 x i8] }>, ptr @str_literal.113, i32 0, i32 2))
  %calltmp149 = call ptr @nova_test_fail_message()
  %ret_ptr_int150 = ptrtoint ptr %calltmp149 to i64
  store i64 %ret_ptr_int150, ptr %tmp_slot151, align 8
  store i64 %ret_ptr_int150, ptr %"msg$7", align 8
  %22 = load i64, ptr %"msg$7", align 8
  %concat_tmp152 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [8 x i8] }>, ptr @str_literal.92, i32 0, i32 2) to i64), i64 %22)
  store i64 %concat_tmp152, ptr %tmp_slot153, align 8
  %puts_ptr154 = inttoptr i64 %concat_tmp152 to ptr
  call void @nova_log_string(ptr %puts_ptr154)
  %tmp_rel155 = load i64, ptr %tmp_slot153, align 8
  call void @nova_release(i64 %tmp_rel155, ptr null)
  store i64 0, ptr %tmp_slot153, align 8
  %23 = load i64, ptr %__test_failed, align 8
  %addtmp156 = add i64 %23, 1
  %int_trunc157 = trunc i64 %addtmp156 to i32
  %int_sext158 = sext i32 %int_trunc157 to i64
  store i64 %int_sext158, ptr %__test_failed, align 8
  %blk_rel_load159 = load i64, ptr %"msg$7", align 8
  call void @nova_release(i64 %blk_rel_load159, ptr null)
  store i64 0, ptr %"msg$7", align 8
  br label %ifcont145

ifcont145:                                        ; preds = %else144, %then143
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [0 x i8] }>, ptr @str_literal.4, i32 0, i32 2))
  %24 = load i64, ptr %__test_passed, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %24)
  %concat_tmp160 = call i64 @string_concat(i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.114, i32 0, i32 2) to i64), i64 %i64_str)
  call void @nova_release(i64 %i64_str, ptr null)
  store i64 %concat_tmp160, ptr %tmp_slot161, align 8
  %concat_tmp162 = call i64 @string_concat(i64 %concat_tmp160, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.115, i32 0, i32 2) to i64))
  store i64 %concat_tmp162, ptr %tmp_slot163, align 8
  %25 = load i64, ptr %__test_failed, align 8
  %i64_str164 = call i64 @nova_i64_to_string(i64 %25)
  %concat_tmp165 = call i64 @string_concat(i64 %concat_tmp162, i64 %i64_str164)
  call void @nova_release(i64 %i64_str164, ptr null)
  store i64 %concat_tmp165, ptr %tmp_slot166, align 8
  %concat_tmp167 = call i64 @string_concat(i64 %concat_tmp165, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [9 x i8] }>, ptr @str_literal.116, i32 0, i32 2) to i64))
  store i64 %concat_tmp167, ptr %tmp_slot168, align 8
  %26 = load i64, ptr %__test_total, align 8
  %i64_str169 = call i64 @nova_i64_to_string(i64 %26)
  %concat_tmp170 = call i64 @string_concat(i64 %concat_tmp167, i64 %i64_str169)
  call void @nova_release(i64 %i64_str169, ptr null)
  store i64 %concat_tmp170, ptr %tmp_slot171, align 8
  %concat_tmp172 = call i64 @string_concat(i64 %concat_tmp170, i64 ptrtoint (ptr getelementptr inbounds nuw (<{ i32, i32, [6 x i8] }>, ptr @str_literal.117, i32 0, i32 2) to i64))
  store i64 %concat_tmp172, ptr %tmp_slot173, align 8
  %puts_ptr174 = inttoptr i64 %concat_tmp172 to ptr
  call void @nova_log_string(ptr %puts_ptr174)
  %tmp_rel175 = load i64, ptr %tmp_slot173, align 8
  call void @nova_release(i64 %tmp_rel175, ptr null)
  store i64 0, ptr %tmp_slot173, align 8
  %tmp_rel176 = load i64, ptr %tmp_slot171, align 8
  call void @nova_release(i64 %tmp_rel176, ptr null)
  store i64 0, ptr %tmp_slot171, align 8
  %tmp_rel177 = load i64, ptr %tmp_slot168, align 8
  call void @nova_release(i64 %tmp_rel177, ptr null)
  store i64 0, ptr %tmp_slot168, align 8
  %tmp_rel178 = load i64, ptr %tmp_slot166, align 8
  call void @nova_release(i64 %tmp_rel178, ptr null)
  store i64 0, ptr %tmp_slot166, align 8
  %tmp_rel179 = load i64, ptr %tmp_slot163, align 8
  call void @nova_release(i64 %tmp_rel179, ptr null)
  store i64 0, ptr %tmp_slot163, align 8
  %tmp_rel180 = load i64, ptr %tmp_slot161, align 8
  call void @nova_release(i64 %tmp_rel180, ptr null)
  store i64 0, ptr %tmp_slot161, align 8
  %calltmp181 = call i64 @nova_arc_audit_report()
  %cmptmp182 = icmp sgt i64 %calltmp181, 0
  %zexttmp183 = zext i1 %cmptmp182 to i64
  %ifcond184 = icmp ne i64 %zexttmp183, 0
  br i1 %ifcond184, label %then185, label %ifcont186

then185:                                          ; preds = %ifcont145
  call void @nova_exit(i32 1)
  br label %ifcont186

ifcont186:                                        ; preds = %then185, %ifcont145
  %27 = load i64, ptr %__test_failed, align 8
  %cmptmp187 = icmp sgt i64 %27, 0
  %zexttmp188 = zext i1 %cmptmp187 to i64
  %ifcond189 = icmp ne i64 %zexttmp188, 0
  br i1 %ifcond189, label %then190, label %ifcont191

then190:                                          ; preds = %ifcont186
  call void @nova_exit(i32 1)
  br label %ifcont191

ifcont191:                                        ; preds = %then190, %ifcont186
  ret i64 0
}

define void @__log_i32(i64 %0) {
entry:
  %tmp_slot = alloca i64, align 8
  store i64 0, ptr %tmp_slot, align 8
  %val = alloca i64, align 8
  store i64 %0, ptr %val, align 8
  %1 = load i64, ptr %val, align 8
  %i64_str = call i64 @nova_i64_to_string(i64 %1)
  store i64 %i64_str, ptr %tmp_slot, align 8
  %puts_ptr = inttoptr i64 %i64_str to ptr
  call void @nova_log_string(ptr %puts_ptr)
  %tmp_rel = load i64, ptr %tmp_slot, align 8
  call void @nova_release(i64 %tmp_rel, ptr null)
  store i64 0, ptr %tmp_slot, align 8
  ret void
}

define void @__log_bool(i64 %0) {
entry:
  %val = alloca i64, align 8
  store i64 %0, ptr %val, align 8
  %1 = load i64, ptr %val, align 8
  %ifcond = icmp ne i64 %1, 0
  br i1 %ifcond, label %then, label %else

then:                                             ; preds = %entry
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [4 x i8] }>, ptr @str_literal.118, i32 0, i32 2))
  br label %ifcont

else:                                             ; preds = %entry
  call void @nova_log_string(ptr getelementptr inbounds nuw (<{ i32, i32, [5 x i8] }>, ptr @str_literal.119, i32 0, i32 2))
  br label %ifcont

ifcont:                                           ; preds = %else, %then
  ret void
}

define i64 @__read_string(i64 %0, i64 %1) {
entry:
  %ptr = alloca i64, align 8
  store i64 %0, ptr %ptr, align 8
  %len = alloca i64, align 8
  store i64 %1, ptr %len, align 8
  %new_ptr = alloca i64, align 8
  store i64 0, ptr %new_ptr, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 8
  %2 = load i64, ptr %len, align 8
  %alloc_tmp = call i64 @nova_bytes_alloc(i64 %2)
  store i64 %alloc_tmp, ptr %new_ptr, align 8
  store i64 0, ptr %i, align 8
  br label %while_cond

while_cond:                                       ; preds = %while_body, %entry
  %3 = load i64, ptr %i, align 8
  %4 = load i64, ptr %len, align 8
  %cmptmp = icmp slt i64 %3, %4
  %zexttmp = zext i1 %cmptmp to i64
  %whilecond = icmp ne i64 %zexttmp, 0
  br i1 %whilecond, label %while_body, label %while_exit

while_body:                                       ; preds = %while_cond
  %5 = load i64, ptr %new_ptr, align 8
  %6 = load i64, ptr %i, align 8
  %7 = load i64, ptr %ptr, align 8
  %8 = load i64, ptr %i, align 8
  %addr = add i64 %7, %8
  %read_ptr = inttoptr i64 %addr to ptr
  %byte_val = load i8, ptr %read_ptr, align 1
  %byte_val_ext = zext i8 %byte_val to i64
  %addr1 = add i64 %5, %6
  %write_ptr = inttoptr i64 %addr1 to ptr
  %byte_val2 = trunc i64 %byte_val_ext to i8
  store i8 %byte_val2, ptr %write_ptr, align 1
  %9 = load i64, ptr %i, align 8
  %addtmp = add i64 %9, 1
  %int_trunc = trunc i64 %addtmp to i32
  %int_sext = sext i32 %int_trunc to i64
  store i64 %int_sext, ptr %i, align 8
  br label %while_cond

while_exit:                                       ; preds = %while_cond
  %10 = load i64, ptr %new_ptr, align 8
  ret i64 %10
}

declare i64 @nova_bytes_alloc(i64)

declare i64 @nova_valopt_box(i64)

declare void @nova_bytes_copy(i64, i64, i64)

define void @__destruct_RawBuffer_i32(i64 %0) {
entry:
  call void @RawBuffer_i32_delete(i64 %0)
  ret void
}

define void @__destruct_RawBuffer_string(i64 %0) {
entry:
  call void @RawBuffer_string_delete(i64 %0)
  ret void
}

define void @__destruct_List_i32(i64 %0) {
entry:
  %field_addr = add i64 %0, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_load = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_load to i64
  call void @nova_release(i64 %ptr_to_int, ptr @__destruct_RawBuffer_i32)
  ret void
}

define void @__destruct_List_string(i64 %0) {
entry:
  %field_addr = add i64 %0, 0
  %field_ptr = inttoptr i64 %field_addr to ptr
  %field_load = load ptr, ptr %field_ptr, align 8
  %ptr_to_int = ptrtoint ptr %field_load to i64
  call void @nova_release(i64 %ptr_to_int, ptr @__destruct_RawBuffer_string)
  ret void
}

declare i64 @nova_bytes_alloc_persistent_nz(i64)

declare i64 @nova_valopt_unbox(i64)

define void @__destruct_StringBuilder(i64 %0) {
entry:
  call void @StringBuilder_delete(i64 %0)
  ret void
}

define void @__destruct_LookupError(i64 %0) {
entry:
  %en_tag_ptr = inttoptr i64 %0 to ptr
  %en_tag = load i64, ptr %en_tag_ptr, align 8
  %en_is = icmp eq i64 %en_tag, 0
  br i1 %en_is, label %en_rel, label %en_next

en_done:                                          ; preds = %en_next2, %en_rel1, %en_rel
  ret void

en_rel:                                           ; preds = %entry
  %en_pay_addr = add i64 %0, 8
  %en_pay_ptr = inttoptr i64 %en_pay_addr to ptr
  %en_pay = load i64, ptr %en_pay_ptr, align 8
  call void @nova_release(i64 %en_pay, ptr null)
  br label %en_done

en_next:                                          ; preds = %entry
  %en_is3 = icmp eq i64 %en_tag, 1
  br i1 %en_is3, label %en_rel1, label %en_next2

en_rel1:                                          ; preds = %en_next
  br label %en_done

en_next2:                                         ; preds = %en_next
  br label %en_done
}

define void @__destruct_ErrUnion_lpstring_LookupError_rp(i64 %0) {
entry:
  %d_tag_ptr = inttoptr i64 %0 to ptr
  %d_tag = load i64, ptr %d_tag_ptr, align 8
  %d_pay_addr = add i64 %0, 8
  %d_pay_ptr = inttoptr i64 %d_pay_addr to ptr
  %d_pay = load i64, ptr %d_pay_ptr, align 8
  %d_is_err = icmp eq i64 %d_tag, 1
  br i1 %d_is_err, label %d_err, label %d_ok

d_err:                                            ; preds = %entry
  call void @nova_release(i64 %d_pay, ptr @__destruct_LookupError)
  br label %d_done

d_ok:                                             ; preds = %entry
  call void @nova_release(i64 %d_pay, ptr null)
  br label %d_done

d_done:                                           ; preds = %d_ok, %d_err
  ret void
}

attributes #0 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: read) }
attributes #2 = { nounwind memory(none) }
attributes #3 = { nounwind }
attributes #4 = { nounwind memory(argmem: read) }
attributes #5 = { nounwind memory(argmem: readwrite) }
