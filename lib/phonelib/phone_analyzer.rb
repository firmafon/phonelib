module Phonelib
  # phone analyzing methods module
  module PhoneAnalyzer
    # array of types not included for validation check in cycle
    NOT_FOR_CHECK = [:general_desc, :fixed_line, :mobile, :fixed_or_mobile]

    # caches regular expression, reusing it for later lookups
    def cr(regexp)
      Phonelib.phone_regexp_cache[regexp] ||= Regexp.new(regexp)
    end

    # parses provided phone if it is valid for  country data and returns result of
    # analyze
    #
    # ==== Attributes
    #
    # * +phone+ - Phone number for parsing
    # * +passed_country+ - Country provided for parsing. Must be ISO code of
    #   country (2 letters) like 'US', 'us' or :us for United States
    def analyze(phone, passed_country)
      country = country_or_default_country passed_country

      result = try_to_parse_single_country(phone, country)
      # if previous parsing failed, trying for all countries
      if result.nil? || result.empty? || result.values.first[:valid].empty?
        detected = detect_and_parse phone
        result = detected.empty? ? result || {} : detected
      end
      result
    end

    private

    # trying to parse phone for single country including international prefix
    # check for provided country
    #
    # ==== Attributes
    #
    # * +phone+ - phone for parsing
    # * +country+ - country to parse phone with
    def try_to_parse_single_country(phone, country)
      data = Phonelib.phone_data[country]
      if country && data
        # if country was provided and it's a valid country, trying to
        # create e164 representation of phone number,
        # kind of normalization for parsing
        e164 = convert_to_e164 phone, data
        # if phone starts with international prefix of provided
        # country try to reanalyze without international prefix for
        # all countries
        return analyze(e164.gsub('+', ''), nil) if e164[0] == '+'
        # trying to parse number for provided country
        parse_single_country e164, data
      end
    end

    # method checks if phone is valid against single provided country data
    #
    # ==== Attributes
    #
    # * +e164+ - e164 representation of phone for parsing
    # * +data+ - country data for single country for parsing
    def parse_single_country(e164, data)
      valid_match = phone_match_data?(e164, data)
      if valid_match
        get_national_and_data(e164, data, valid_match)
      else
        possible_match = phone_match_data?(e164, data, true)
        possible_match && get_national_and_data(e164, data, possible_match)
      end
    end

    # method tries to detect what is the country for provided phone
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    def detect_and_parse(phone)
      result = {}
      Phonelib.phone_data.each do |key, data|
        parsed = parse_single_country(phone, data)
        result.merge!(parsed) unless parsed.nil?
      end
      result
    end

    # Get country that was provided or default country in needable format
    #
    # ==== Attributes
    #
    # * +country+ - country passed for parsing
    def country_or_default_country(country)
      country = country || Phonelib.default_country
      country && country.to_s.upcase
    end

    # Create phone representation in e164 format
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+  - country data to be based on for creating e164 representation
    def convert_to_e164(phone, data)
      match = phone.match full_regex_for_data(data, Core::VALID_PATTERN)
      case
      when match
        national_start = (1..3).map { |i| match[i].to_s.length }.inject(:+)
        "#{data[Core::COUNTRY_CODE]}#{phone[national_start..-1]}"
      when phone.match(cr("^#{data[Core::INTERNATIONAL_PREFIX]}"))
        phone.sub(cr("^#{data[Core::INTERNATIONAL_PREFIX]}"), '+')
      else
        "#{data[Core::COUNTRY_CODE]}#{phone}"
      end
    end

    # constructs full regex for phone validation for provided phone data
    # (international prefix, country code, national prefix, valid number)
    #
    # ==== Attributes
    #
    # * +data+ - country data hash
    # * +country_optional+ - whether to put country code as optional group
    def full_regex_for_data(data, type, country_optional = true)
      regex = []
      regex << "(#{data[Core::INTERNATIONAL_PREFIX]})?"
      regex << if country_optional
                 "(#{data[Core::COUNTRY_CODE]})?"
               else
                 data[Core::COUNTRY_CODE]
               end
      regex << "(#{data[Core::NATIONAL_PREFIX_FOR_PARSING] || data[Core::NATIONAL_PREFIX]})?"
      regex << "(#{data[Core::TYPES][Core::GENERAL][type]})"

      cr("^#{regex.join}$")
    end

    # returns national number and analyzing results for provided phone number
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+ - country data
    # * +country_match+ - result of match of phone within full regex
    def get_national_and_data(phone, data, country_match)
      prefix_length = data[Core::COUNTRY_CODE].length
      prefix_length += [1, 2].map { |i| country_match[i].to_s.size }.inject(:+)
      result = data.select { |k, v| k != :types && k != :formats }
      result[:national] = phone[prefix_length..-1]
      result[:format] = get_number_format(result[:national],
                                          data[Core::FORMATS])
      result.merge! all_number_types(result[:national], data[Core::TYPES])
      { result[:id] => result }
    end

    # Check if phone match country data
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+  - country data
    def phone_match_data?(phone, data, possible = false)
      return unless phone.match phone_match_regexp(data)

      type = possible ? Core::POSSIBLE_PATTERN : Core::VALID_PATTERN
      phone.match full_regex_for_data(data, type, false)
    end

    # Returns all valid and possible phone number types for currently parsed
    # phone for provided data hash.
    #
    # ==== Attributes
    #
    # * +phone+ - phone number for parsing
    # * +data+  - country data
    def all_number_types(phone, data)
      response = { valid: [], possible: [] }

      types_for_check(data).each do |type|
        possible, valid = get_patterns(data, type)

        valid_and_possible, possible_result =
            number_valid_and_possible?(phone, possible, valid)
        response[:possible] << type if possible_result
        response[:valid] << type if valid_and_possible
      end

      sanitize_fixed_mobile(response)
    end

    # checks if types has both :mobile and :fixed_line and replaces it with
    # :fixed_or_mobile in case both present
    def sanitize_fixed_mobile(types)
      fixed_mobile = [Core::FIXED_LINE, Core::MOBILE]
      [:possible, :valid].each do |key|
        if (fixed_mobile - types[key]).empty?
          types[key] = types[key] - fixed_mobile + [Core::FIXED_OR_MOBILE]
        end
      end
      types
    end

    # returns array of phone types for check for current country data
    #
    # ==== Attributes
    #
    # * +data+  - country data hash
    def types_for_check(data)
      Core::TYPES_DESC.keys - PhoneAnalyzer::NOT_FOR_CHECK +
          fixed_and_mobile_keys(data)
    end

    # Gets matched number formatting rule or default one
    #
    # ==== Attributes
    #
    # * +national+ - national phone number
    # * +format_data+  - formatting data from country data
    def get_number_format(national, format_data)
      format_data && format_data.find do |format|
        (format[Core::LEADING_DIGITS].nil? \
            || national.match(cr("^(#{format[Core::LEADING_DIGITS]})"))) \
        && national.match(cr("^(#{format[Core::PATTERN]})$"))
      end || Core::DEFAULT_NUMBER_FORMAT
    end

    # Checks if fixed line pattern and mobile pattern are the same and returns
    # appropriate keys
    #
    # ==== Attributes
    #
    # * +data+  - country data
    def fixed_and_mobile_keys(data)
      if data[Core::FIXED_LINE] == data[Core::MOBILE]
        [Core::FIXED_OR_MOBILE]
      else
        [Core::FIXED_LINE, Core::MOBILE]
      end
    end

    # Returns possible and valid patterns for validation for provided type
    #
    # ==== Attributes
    #
    # * +all_patterns+ - hash of all patterns for validation
    # * +type+ - type of phone to get patterns for
    def get_patterns(all_patterns, type)
      type = Core::FIXED_LINE if type == Core::FIXED_OR_MOBILE
      patterns = all_patterns[type]

      if patterns.nil?
        [nil, nil]
      else
        [patterns[Core::POSSIBLE_PATTERN], patterns[Core::VALID_PATTERN]]
      end
    end

    # Checks if passed number matches valid and possible patterns
    #
    # ==== Attributes
    #
    # * +number+ - phone number for validation
    # * +possible_pattern+ - possible pattern for validation
    # * +national_pattern+ - valid pattern for validation
    def number_valid_and_possible?(number, possible_pattern, national_pattern)
      possible_match = number.match(complete_pattern_regexp(possible_pattern))
      possible = possible_match && possible_match.to_s.length == number.length

      return [possible, possible] if possible_pattern == national_pattern
      valid = false
      if possible
        # doing national pattern match only in case possible matches
        national_match = number.match(complete_pattern_regexp(national_pattern))
        valid = national_match && national_match.to_s.length == number.length
      end

      [valid && possible, possible]
    end

    private

    # Prevent major String allocations by caching this Regexp used in the
    # `phone_match_data?` hotspot.
    PHONE_MATCH_REGEXPS = Hash.new do |h, international_prefix|
      h[international_prefix] = Hash.new do |h2, country_code|
        h2[country_code] = Regexp.new("^(#{international_prefix})?#{country_code}")
      end
    end

    PATTERN_REGEXPS = Hash.new { |h,k| h[k] = Regexp.new("^(?:#{k})$") }

    def phone_match_regexp(data)
      PHONE_MATCH_REGEXPS[data[Core::INTERNATIONAL_PREFIX]][data[Core::COUNTRY_CODE]]
    end

    def complete_pattern_regexp(pattern)
      PATTERN_REGEXPS[pattern]
    end
  end
end
