require 'minitest/autorun'
require_relative 'download_all_signed_docs'
require 'ostruct'

class TestFileDownloadStatus < Minitest::Test
  def setup
    @status = FileDownloadStatus.new(id: 'abc123', title: 'Test Doc')
  end

  def test_initial_state
    assert_equal :pending, @status.state
    assert_nil @status.filename
    assert_nil @status.error_message
  end

  def test_start_download
    @status.start_download
    assert_equal :downloading, @status.state
  end

  def test_mark_success
    @status.mark_success('file.pdf')
    assert_equal :success, @status.state
    assert_equal 'file.pdf', @status.filename
  end

  def test_mark_error
    @status.mark_error('fail')
    assert_equal :error, @status.state
    assert_equal 'fail', @status.error_message
  end

  def test_skip
    @status.skip('not needed')
    assert_equal :skipped, @status.state
    assert_equal 'not needed', @status.error_message
  end

  def test_to_h
    @status.mark_success('file.pdf')
    h = @status.to_h
    assert_equal 'abc123', h[:id]
    assert_equal 'Test Doc', h[:title]
    assert_equal 'file.pdf', h[:filename]
    assert_equal :success, h[:state]
    assert_nil h[:error_message]
  end
end

class TestHelloSignDownloader < Minitest::Test
  def setup
    @downloader = HelloSignDownloader.new(api_key: 'dummy', output_folder: './tmp_test')
  end

  def test_sanitize_filename
    assert_equal 'Test_Doc', @downloader.sanitize_filename('Test Doc', 'fallback')
    assert_equal 'fallback', @downloader.sanitize_filename('', 'fallback')
    assert_equal 'abc123', @downloader.sanitize_filename(nil, 'abc123')
    assert_equal 'A_B_C', @downloader.sanitize_filename('A/B:C', 'fallback')
  end

  def test_net_http_get_success
    # Use Minitest::Mock to simulate Net::HTTP
    mock_response = OpenStruct.new(code: '200', body: 'ok')
    mock_http = Minitest::Mock.new
    mock_http.expect(:use_ssl=, true, [true])
    mock_http.expect(:request, mock_response, [Net::HTTP::Get])

    Net::HTTP.stub :new, mock_http do
      result = @downloader.net_http_get('https://example.com')
      assert_equal 200, result.code
      assert_equal 'ok', result.body
    end
  end

  def test_download_with_retry_429
    # Simulate 2x 429 then 200 using a counter and stub
    call_count = 0
    responses = [
      OpenStruct.new(code: 429, body: ''),
      OpenStruct.new(code: 429, body: ''),
      OpenStruct.new(code: 200, body: 'ok')
    ]
    @downloader.define_singleton_method(:net_http_get) do |*args|
      resp = responses[call_count]
      call_count += 1
      resp
    end
    @downloader.define_singleton_method(:sleep) { |*args| nil }
    result = @downloader.download_with_retry('https://example.com', {})
    assert_equal 200, result.code
    assert_equal 'ok', result.body
  end
end 