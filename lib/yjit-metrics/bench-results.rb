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

    def rel_stddev(values)
        stddev(values) / mean(values)
    end

    def rel_stddev_pct(values)
        100.0 * stddev(values) / mean(values)
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
    # Note that this input structure doesn't represent runs (subgroups of iterations),
    # such as when restarting the benchmark and doing, say, 10 groups of 300
    # niterations. To represent that, you would call this method 10 times, once per
    # run. Runs will be kept separate internally, but by default are returned as a
    # combined single array.
    #
    # Every benchmark run is assumed to come with a corresponding metadata hash
    # and (optional) hash of YJIT stats. However, there should normally only
    # be one set of Ruby metadata, not one per benchmark run. Ruby metadata is
    # assumed to be constant for a specific compiled copy of Ruby over all runs.
    def add_for_config(config_name, benchmark_results)
        if benchmark_results["version"] != 2
            raise "Getting data from older version-1 data file or JSON in bad format!"
        end

        @times[config_name] ||= {}
        benchmark_results["times"].each do |benchmark_name, times|
            @times[config_name][benchmark_name] ||= []
            @times[config_name][benchmark_name].concat(times)
        end

        @warmups[config_name] ||= {}
        (benchmark_results["warmups"] || {}).each do |benchmark_name, warmups|
            @warmups[config_name][benchmark_name] ||= []
            @warmups[config_name][benchmark_name].concat(warmups)
        end

        @yjit_stats[config_name] ||= {}
        benchmark_results["yjit_stats"].each do |benchmark_name, stats_array|
            next if stats_array.nil?
            stats_array.compact!
            next if stats_array.empty?
            @yjit_stats[config_name][benchmark_name] ||= []
            @yjit_stats[config_name][benchmark_name].concat(stats_array)
        end

        @benchmark_metadata[config_name] ||= {}
        benchmark_results["benchmark_metadata"].each do |benchmark_name, metadata_for_benchmark|
            @benchmark_metadata[config_name][benchmark_name] ||= metadata_for_benchmark
            if @benchmark_metadata[config_name][benchmark_name] != metadata_for_benchmark
                # We don't print this warning only once because it's really bad, and because we'd like to show it for all
                # relevant problem benchmarks. But mostly because it's really bad: don't combine benchmark runs with
                # different settings into one result set.
                $stderr.puts "WARNING: multiple benchmark runs of #{benchmark_name} in #{config_name} have different benchmark metadata!"
            end
        end

        @ruby_metadata[config_name] ||= benchmark_results["ruby_metadata"]
        if @ruby_metadata[config_name] != benchmark_results["ruby_metadata"] && !@printed_ruby_metadata_warning
            print "Ruby metadata is meant to *only* include information that should always be\n" +
              "  the same for the same Ruby executable. Please verify that you have not added\n" +
              "  inappropriate Ruby metadata or accidentally used the same name for two\n" +
              "  different Ruby executables. (Additional mismatches in this result set won't show warnings.)\n"
            puts "Metadata 1: #{@ruby_metadata[config_name].inspect}"
            puts "Metadata 2: #{benchmark_results["ruby_metadata"].inspect}"
            @printed_ruby_metadata_warning = true
        end
    end

    # This returns a hash-of-arrays by configuration name
    # containing benchmark results (times) per
    # benchmark for the specified config.
    #
    # If in_runs is specified, the array will contain
    # arrays (runs) of samples. Otherwise all samples
    # from all runs will be combined.
    def times_for_config_by_benchmark(config, in_runs: false)
        raise("No results for configuration: #{config.inspect}!") if !@times.has_key?(config) || @times[config].empty?
        return @times[config] if in_runs
        data = {}
        @times[config].each do |benchmark_name, runs|
            data[benchmark_name] = runs.inject([]) { |arr, piece| arr.concat(piece) }
        end
        data
    end

    # This returns a hash-of-arrays by configuration name
    # containing warmup results (times) per
    # benchmark for the specified config.
    #
    # If in_runs is specified, the array will contain
    # arrays (runs) of samples. Otherwise all samples
    # from all runs will be combined.
    def warmups_for_config_by_benchmark(config, in_runs: false)
        return @warmups[config] if in_runs
        data = {}
        @warmups[config].each do |benchmark_name, runs|
            data[benchmark_name] = runs.inject([]) { |arr, piece| arr.concat(piece) }
        end
        data
    end

    # This returns a hash-of-arrays by config name
    # containing YJIT statistics, if gathered, per
    # benchmark run for the specified config. For configs
    # that don't collect YJIT statistics, the array
    # will be empty.
    #
    # If in_runs is specified, the array will contain
    # arrays (runs) of samples. Otherwise all samples
    # from all runs will be combined.
    def yjit_stats_for_config_by_benchmark(config, in_runs: false)
        return @yjit_stats[config] if in_runs
        data = {}
        @yjit_stats[config].each do |benchmark_name, runs|
            data[benchmark_name] = runs.inject([]) { |arr, piece| arr.concat(piece) }
        end
        data
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

    # What Ruby configurations does this ResultSet contain data for?
    def available_configs
        @ruby_metadata.keys
    end

    # What Ruby configurations, if any, have full YJIT statistics available?
    def configs_containing_full_yjit_stats
        @yjit_stats.keys.select do |config_name|
            stats = @yjit_stats[config_name]

            # Every benchmark gets a key/value pair in stats, and every
            # value is an array of arrays -- each run gets an array, and
            # each measurement in the run gets an array (TODO: is this too complicated?)

            # Even "non-stats" YJITs now have statistics, but not "full" statistics
            !stats.nil? &&
                !stats.empty? &&
                !stats.values.all? { |val| val[0][0]["all_stats"].nil? }
        end
    end
end

# Shared utility methods for reports
class YJITMetrics::Report
    include YJITMetrics::Stats

    def initialize(config_names, results, benchmarks: [])
        raise "No Rubies specified!" if config_names.empty?

        bad_configs = config_names - results.available_configs
        raise "Unknown configurations in report: #{bad_configs.inspect}!" unless bad_configs.empty?

        @config_names = config_names
        @only_benchmarks = benchmarks
        @result_set = results
    end

    def filter_benchmark_names(names)
        return names if @only_benchmarks.empty?
        names.select { |bench_name| @only_benchmarks.any? { |bench_spec| bench_name.start_with?(bench_spec) } }
    end

    # Take column headings, formats for the percent operator and data, and arrange it
    # into a simple ASCII table returned as a string.
    def format_as_table(headings, col_formats, data, separator_character: "-", column_spacer: "  ")
        out = ""

        unless data && data[0] && col_formats && col_formats[0] && headings && headings[0]
            $stderr.puts "Error in format_as_table..."
            $stderr.puts "Headings: #{headings.inspect}"
            $stderr.puts "Col formats: #{col_formats.inspect}"
            $stderr.puts "Data: #{data.inspect}"
            raise "Invalid data sent to format_as_table"
        end

        num_cols = data[0].length
        raise "Mismatch between headings and first data row for number of columns!" unless headings.length == num_cols
        raise "Data has variable number of columns!" unless data.all? { |row| row.length == num_cols }
        raise "Column formats have wrong number of entries!" unless col_formats.length == num_cols

        formatted_data = data.map.with_index do |row, idx|
            col_formats.zip(row).map { |fmt, item| item ? fmt % item : "" }
        end

        col_widths = (0...num_cols).map { |col_num| (formatted_data.map { |row| row[col_num].length } + [ headings[col_num].length ]).max }

        out.concat(headings.map.with_index { |h, idx| "%#{col_widths[idx]}s" % h }.join(column_spacer), "\n")

        separator = col_widths.map { |width| separator_character * width }.join(column_spacer)
        out.concat(separator, "\n")

        formatted_data.each do |row|
            out.concat (row.map.with_index { |item, idx| " " * (col_widths[idx] - item.size) + item }).join(column_spacer), "\n"
        end

        out.concat("\n", separator, "\n")
    rescue
        $stderr.puts "Error when trying to format table: #{headings.inspect} / #{col_formats.inspect} / #{data[0].inspect}"
        raise
    end

    def write_to_csv(filename, data)
        CSV.open(filename, "wb") do |csv|
            data.each { |row| csv << row }
        end
    end

end
