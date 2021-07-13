# Make sure YJITMetrics namespace is declared
module YJITMetrics; end

# Statistical methods
module YJITMetrics::Stats
    def mean(values)
        return values.sum(0.0) / values.size
    end

    def stddev(values)
        xbar = mean(values)
        diff_sqrs = values.map { |v| (v-xbar)*(v-xbar) }
        # Bessel's correction requires dividing by length - 1, not just length:
        # https://en.wikipedia.org/wiki/Standard_deviation#Corrected_sample_standard_deviation
        variance = diff_sqrs.sum(0.0) / (values.length - 1)
        return Math.sqrt(variance)
    end
end

# Encapsulate multiple benchmark runs across multiple Ruby configurations.
# Do simple calculations, reporting and file I/O.
#
# Note that a JSON file with many results can be quite large.
# Normally it's appropriate to store raw data as multiple JSON files
# that contain one set of runs each. Large multi-Ruby datasets
# may not be practical to save as full raw data.
class YJITMetrics::ResultSet
    include YJITMetrics::Stats

    def initialize
        @times = {}
        @warmups = {}
        @benchmark_metadata = {}
        @ruby_metadata = {}
        @yjit_stats = {}
    end

    # A ResultSet normally expects to see results with this structure:
    #
    # {
    #   "times" => { "benchname1" => [ 11.7, 14.5, 16.7, ... ], "benchname2" => [...], ... },
    #   "benchmark_metadata" => { "benchname1" => {...}, "benchname2" => {...}, ... },
    #   "ruby_metadata" => {...},
    #   "yjit_stats" => { "benchname1" => [{...}, {...}...], "benchname2" => [{...}, {...}, ...] }
    # }
    #
    # Note that this doesn't track "batches" of runs, such as when restarting
    # the benchmark and doing, say, 10 batches of 30. Instead, if they're added
    # via 30 calls to the method below, they will be combined into a single
    # array of 300 measurements.
    #
    # Every benchmark run is assumed to come with a corresponding metadata hash
    # and (optional) hash of YJIT stats. However, there should normally only
    # be one set of Ruby metadata, not one per benchmark run.
    def add_for_config(config_name, benchmark_results)
        @times[config_name] ||= {}
        benchmark_results["times"].each do |benchmark_name, times|
            @times[config_name][benchmark_name] ||= []
            @times[config_name][benchmark_name].concat(times)
        end

        @warmups[config_name] ||= {}
        (benchmark_results["warmups"] || {}).each do |benchmark_name, warmups|
            @times[config_name][benchmark_name] ||= []
            @times[config_name][benchmark_name].concat(warmups)
        end

        @benchmark_metadata[config_name] ||= {}
        benchmark_results["benchmark_metadata"].each do |benchmark_name, metadata_for_benchmark|
            @benchmark_metadata[config_name][benchmark_name] ||= metadata_for_benchmark
            if @benchmark_metadata[config_name][benchmark_name] != metadata_for_benchmark
                STDERR.puts "WARNING: multiple benchmark runs of #{benchmark_name} in #{config_name} have different benchmark metadata!"
            end
        end

        @ruby_metadata[config_name] ||= benchmark_results["ruby_metadata"]
        if @ruby_metadata[config_name] != benchmark_results["ruby_metadata"]
            print "Ruby metadata is meant to *only* include information that should always be\n" +
              "  the same for the same Ruby executable. Please verify that you have not added\n" +
              "  inappropriate Ruby metadata or accidentally used the same name for two\n"
              "  different Ruby executables.\n"
            raise "Ruby metadata does not match for same configuration name!"
        end

        @yjit_stats[config_name] ||= {}
        benchmark_results["yjit_stats"].each do |benchmark_name, stats_array|
            @yjit_stats[config_name][benchmark_name] ||= []
            @yjit_stats[config_name][benchmark_name].concat(stats_array)
        end
    end

    # This returns a hash-of-arrays by configuration name
    # containing benchmark results (times) per
    # benchmark for the specified config.
    def times_for_config_by_benchmark(config)
        raise("No results for configuration: #{config.inspect}!") if !@times.has_key?(config) || @times[config].empty?
        @times[config]
    end

    # This returns a hash-of-arrays by configuration name
    # containing warmup results (times) per
    # benchmark for the specified config.
    def warmups_for_config_by_benchmark(config)
        @warmups[config]
    end

    # This returns a hash-of-hashes by config name
    # containing YJIT statistics, if gathered, per
    # benchmark for the specified config. For configs
    # that don't collect YJIT statistics, the inner
    # hash will be empty.
    def yjit_stats_for_config_by_benchmark(config)
        @yjit_stats[config]
    end

    # This returns a hash-of-hashes by config name
    # containing per-benchmark metadata (parameters) per
    # benchmark for the specified config.
    def benchmark_metadata_for_config_by_benchmark(config)
        @benchmark_metadata[config]
    end

    # This returns a hash of metadata for the given config name
    def metadata_for_config(config)
        @ruby_metadata[config]
    end

    # Output a CSV file which contains metadata as key/value pairs, followed by a blank row, followed by the raw time data
    def to_csv
        output_rows = @metadata.keys.zip(@metadata.values)
        output_rows << []
        output_rows.concat(@data)

        csv_out = ""
        csv = CSV.new(csv_out)
        output_rows.each { |row| csv << row }
        csv_out
    end
end

# We'd like to be able to create a quick columnar report, often for one
# Ruby config versus another, and load/dump it as JSON or CSV. This isn't a
# report class that is all things to all people -- it's specifically
# a comparison of two or more configurations per-benchmark for yjit-bench.
#
# The first configuration given is assumed to be the baseline against
# which the other configs are measured.
class YJITMetrics::PerBenchRubyComparison
    include YJITMetrics::Stats

    def initialize(config_names, results)
        raise "No Rubies specified!" if config_names.empty?

        @config_names = config_names
        @result_set = results

        @headings = [ "bench" ] + config_names.flat_map { |config| [ "#{config} (ms)", "rel stddev (%)" ] } + alt_configs.map { |config| "#{config}/#{base_config}" }
        @col_formats = [ "%s" ] + config_names.flat_map { [ "%.1f", "%.1f" ] } + alt_configs.map { "%.2f" }

        @report_data = []
        times_by_config = {}
        config_names.each { |config| times_by_config[config] = results.times_for_config_by_benchmark(config) }

        benchmark_names = times_by_config[config_names[0]].keys

        times_by_config.each do |config_name, results|
            raise("No results for configuration #{config_name.inspect} in PerBenchRubyComparison!") if results.nil?
        end

        benchmark_names.each do |benchmark_name|
            row = [ benchmark_name ]
            config_names.each do |config|
                unless times_by_config[config][benchmark_name]
                    raise("Configuration #{config.inspect} has no results for #{benchmark_name.inspect} even though #{config_names[0]} does in the same dataset!")
                end
                config_times = times_by_config[config][benchmark_name]
                config_mean = mean(config_times)
                row.push config_mean
                row.push 100.0 * stddev(config_times) / config_mean
            end

            base_config_mean = mean(times_by_config[base_config][benchmark_name])
            alt_configs.each do |config|
                config_mean = mean(times_by_config[config][benchmark_name])
                row.push config_mean / base_config_mean
            end

            @report_data.push row
        end
    end

    def base_config
        @config_names[0]
    end

    def alt_configs
        @config_names[1..-1]
    end

    def write_to_csv(filename)
        CSV.open(filename, "wb") do |csv|
            csv << @headings
            @report_data.each { |row| csv << row }
        end
    end

    def to_s
        out = ""

        num_cols = @report_data[0].length

        row_data = @report_data.map.with_index do |row, idx|
            @col_formats.zip(row).map { |fmt, data| fmt % data }
        end

        col_widths = (0...num_cols).map { |col_num| row_data.map { |row| row[col_num].length }.max }

        separator = col_widths.map { |width| "-" * width }.join("  ")
        out.concat(separator, "\n")

        row_data.each do |row|
            out.concat (row.map.with_index { |item, idx| " " * (col_widths[idx] - item.size) + item }).join("  ")
        end

        out.concat("\n", separator, "\n")
        out.concat(config_legend_text)
    end

    def config_legend_text
        "\nLegend:\n" +
        alt_configs.map do |config|
            "- #{config}/#{base_config}: ratio of mean(#{config} times)/mean(#{base_config} times). >1 means #{base_config} is faster.\n"
        end.join + "\n"
    end
end

class YJITMetrics::YJITStatsReport
    def initialize(config_name, results)
        @config_name = config_name
        @result_set = results

        bench_yjit_stats = @result_set.yjit_stats_for_config_by_benchmark(config_name)
        raise("This config collected no YJIT stats!") if bench_yjit_stats.values.all?(&:empty?)

        @benchmark_names = bench_yjit_stats.keys
    end

    # Pretend that all these listed benchmarks ran inside a single Ruby process. Combine their statistics and print an exit report.
    # TODO: add a mechanism for a "zero" result set from an empty YJIT run, then subtract that from each result set before combining.
    def combined_data_for_benchmarks(benchmark_names)
        unless benchmark_names.all? { |benchmark_name| @benchmark_names.include?(benchmark_name) }
            raise "No data found for benchmark #{benchmark_name.inspect}!"
        end

        all_yjit_stats = @result_set.yjit_stats_for_config_by_benchmark[@config_name]
        relevant_stats = benchmark_names.flat_map { |benchmark_name| all_yjit_stats[benchmark_name] }.select { |data| !data.empty? }

        if relevant_stats.empty?
            raise "No YJIT stats data found for benchmarks: #{benchmark_names.inspect}!"
        end

        # For each key in the YJIT statistics, add up the value for that key in all datasets.
        yjit_stat_keys = relevant_stats[0].keys
        yjit_data = {}
        yjit_stats_keys.each do |stats_key|
            # Unknown keys default to 0.
            yjit_data[stats_key] = relevant_stats.map { |dataset| dataset[stats_key] || 0 }.sum
        end
        yjit_data
    end
end

# This is intended to match the exit report printed by debug YJIT when stats are turned on.
class YJITMetrics::YJITStatsExitReport < YJITMetrics::YJITStatsReport
    def exit_report_for_benchmarks(benchmark_names)
        yjit_stats = combined_data_for_benchmarks(benchmark_names)
    end
end

class YJITMetrics::YJITStatsReport
    attr_reader :config

    # These counters aren't for "can't compile" or "side exit",
    # they're for various other things.
    COUNTERS_MISC = [
        "exec_instruction",     # YJIT instructions that *start* to execute, even if they later side-exit
        "leave_interp_return",  # Number of returns to the interpreter
        "binding_allocations",  # Number of times Ruby allocates a binding (via proc.c:rb_binding_alloc)
        "binding_set",          # Number of locals modified via a binding (via proc.c:bind_local_variable_set)
    ]

    COUNTERS_SIDE_EXITS = %w(
        setivar_val_heapobject
        setivar_frozen
        setivar_idx_out_of_range
        getivar_undef
        getivar_idx_out_of_range
        getivar_se_self_not_heap
        setivar_se_self_not_heap
        oaref_arg_not_fixnum
        send_se_protected_check_failed
        send_se_cf_overflow
        leave_se_finish_frame
        leave_se_interrupt
        send_se_protected_check_failed
        )

    COUNTERS_CANT_COMPILE = %w(
        send_callsite_not_simple
        send_kw_splat
        send_bmethod
        send_zsuper_method
        send_refined_method
        send_ivar_set_method
        send_undef_method
        send_optimized_method
        send_missing_method
        send_cfunc_toomany_args
        send_cfunc_argc_mismatch
        send_cfunc_ruby_array_varg
        send_iseq_tailcall
        send_iseq_arity_error
        send_iseq_only_keywords
        send_iseq_complex_callee
        send_not_implemented_method
        send_getter_arity
        getivar_name_not_mapped
        setivar_name_not_mapped
        setivar_not_object
        oaref_argc_not_one
        )

    def initialize(config_name, results)
        @config_name = config_name
        @result_set = results

        bench_yjit_stats = @result_set.yjit_stats_for_config_by_benchmark(config_name)
        raise("This config collected no YJIT stats!") if bench_yjit_stats.values.all?(&:empty?)

        @benchmark_names = bench_yjit_stats.keys
        @headings = [ "bench",  ]

        @report_data = []
    end

    def as_text_table
        out = ""

        out
    end

end

# Current YJIT stats as saved:
# "exec_instruction": 202832371,  # YJIT instructions that *start* to execute, even if they later side-exit
# "leave_interp_return": 4049518,   # Number of returns to the interpreter
# "binding_allocations": 0,  # Number of times Ruby allocates a binding (via proc.c:rb_binding_alloc)
# "binding_set": 0  # Number of locals modified through binding (via proc.c:bind_local_variable_set)
