# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class CheckDataTest < Minitest::Test
  def run_check(*args)
    script = File.expand_path("check-data.rb", __dir__)
    Open3.capture3({ "DATA_DIR" => nil }, RbConfig.ruby, script, *args)
  end

  def test_tab_without_an_id_does_not_fall_back_to_all_tabs
    stdout, stderr, status = run_check("--tab")
    refute status.success?, stdout
    assert_match(/--tab: expected a tab ID/, stderr)
  end

  def test_misspelled_links_flag_does_not_pass_without_checking_links
    stdout, stderr, status = run_check("--linsk")
    refute status.success?, stdout
    assert_match(/unknown argument: --linsk/, stderr)
  end

  def test_repeated_tab_flags_check_only_the_requested_tabs
    stdout, stderr, status = run_check("--tab", "overview", "--tab", "iac")
    assert status.success?, stderr
    assert_match(/\AOK: 2 tabs,/, stdout)
  end
end
