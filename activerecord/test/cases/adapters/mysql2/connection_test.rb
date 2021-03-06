require "cases/helper"

class MysqlConnectionTest < ActiveRecord::TestCase
  def setup
    super
    @subscriber = SQLSubscriber.new
    ActiveSupport::Notifications.subscribe('sql.active_record', @subscriber)
    @connection = ActiveRecord::Base.connection
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    super
  end

  def test_bad_connection
    assert_raise ActiveRecord::NoDatabaseError do
      configuration = ActiveRecord::Base.configurations['arunit'].merge(database: 'inexistent_activerecord_unittest')
      connection = ActiveRecord::Base.mysql2_connection(configuration)
      connection.exec_query('drop table if exists ex')
    end
  end

  def test_no_automatic_reconnection_after_timeout
    assert @connection.active?
    @connection.update('set @@wait_timeout=1')
    sleep 2
    assert !@connection.active?

    # Repair all fixture connections so other tests won't break.
    @fixture_connections.each do |c|
      c.verify!
    end
  end

  def test_session_timezone
    original_timezone = ActiveRecord::Base.default_timezone
    global_mysql_timezones = []

    # checking session timezone while the config value is :utc
    ActiveRecord::Base.default_timezone = :utc
    @connection.reconnect!
    session_mysql_timezone = @connection.exec_query "SELECT @@SESSION.time_zone"
    global_mysql_timezones << @connection.exec_query("SELECT @@GLOBAL.time_zone").rows[0]
    assert_equal [["+00:00"]], session_mysql_timezone.rows, "Session time_zone not set correctly."

    # checking session timezone while the config value is :local
    ActiveRecord::Base.default_timezone = :local
    @connection.reconnect!
    session_mysql_timezone = @connection.exec_query "SELECT @@SESSION.time_zone"
    global_mysql_timezones << @connection.exec_query("SELECT @@GLOBAL.time_zone").rows[0]
    assert_equal [[DateTime.now.zone]], session_mysql_timezone.rows, "Session time_zone not set correctly."

    # checking session timezone while the config value is otherwise
    ActiveRecord::Base.default_timezone = ''
    @connection.reconnect!
    session_mysql_timezone = @connection.exec_query "SELECT @@SESSION.time_zone"
    global_mysql_timezones << @connection.exec_query("SELECT @@GLOBAL.time_zone").rows[0]
    assert_equal [[DateTime.now.zone]], session_mysql_timezone.rows, "Session time_zone not set correctly."

    # global value should remain unaffected
    assert_equal 1, global_mysql_timezones.uniq.count, "Global mysql time_zone shouldn't change."

    ActiveRecord::Base.default_timezone = original_timezone
    @connection.reconnect!
  end

  def test_successful_reconnection_after_timeout_with_manual_reconnect
    assert @connection.active?
    @connection.update('set @@wait_timeout=1')
    sleep 2
    @connection.reconnect!
    assert @connection.active?
  end

  def test_successful_reconnection_after_timeout_with_verify
    assert @connection.active?
    @connection.update('set @@wait_timeout=1')
    sleep 2
    @connection.verify!
    assert @connection.active?
  end

  # TODO: Below is a straight up copy/paste from mysql/connection_test.rb
  # I'm not sure what the correct way is to share these tests between
  # adapters in minitest.
  def test_mysql_default_in_strict_mode
    result = @connection.exec_query "SELECT @@SESSION.sql_mode"
    assert_equal [["STRICT_ALL_TABLES"]], result.rows
  end

  def test_mysql_strict_mode_disabled_dont_override_global_sql_mode
    run_without_connection do |orig_connection|
      ActiveRecord::Base.establish_connection(orig_connection.merge({:strict => false}))
      global_sql_mode = ActiveRecord::Base.connection.exec_query "SELECT @@GLOBAL.sql_mode"
      session_sql_mode = ActiveRecord::Base.connection.exec_query "SELECT @@SESSION.sql_mode"
      assert_equal global_sql_mode.rows, session_sql_mode.rows
    end
  end

  def test_mysql_set_session_variable
    run_without_connection do |orig_connection|
      ActiveRecord::Base.establish_connection(orig_connection.deep_merge({:variables => {:default_week_format => 3}}))
      session_mode = ActiveRecord::Base.connection.exec_query "SELECT @@SESSION.DEFAULT_WEEK_FORMAT"
      assert_equal 3, session_mode.rows.first.first.to_i
    end
  end

  def test_mysql_set_session_variable_to_default
    run_without_connection do |orig_connection|
      ActiveRecord::Base.establish_connection(orig_connection.deep_merge({:variables => {:default_week_format => :default}}))
      global_mode = ActiveRecord::Base.connection.exec_query "SELECT @@GLOBAL.DEFAULT_WEEK_FORMAT"
      session_mode = ActiveRecord::Base.connection.exec_query "SELECT @@SESSION.DEFAULT_WEEK_FORMAT"
      assert_equal global_mode.rows, session_mode.rows
    end
  end

  def test_logs_name_show_variable
    @connection.show_variable 'foo'
    assert_equal "SCHEMA", @subscriber.logged[0][1]
  end

  def test_logs_name_rename_column_sql
    @connection.execute "CREATE TABLE `bar_baz` (`foo` varchar(255))"
    @subscriber.logged.clear
    @connection.send(:rename_column_sql, 'bar_baz', 'foo', 'foo2')
    assert_equal "SCHEMA", @subscriber.logged[0][1]
  ensure
    @connection.execute "DROP TABLE `bar_baz`"
  end

  private

  def run_without_connection
    original_connection = ActiveRecord::Base.remove_connection
    begin
      yield original_connection
    ensure
      ActiveRecord::Base.establish_connection(original_connection)
    end
  end
end
