class NoBrainer::Profiler::Query
  include NoBrainer::Document
  include NoBrainer::Document::Timestamps

  disable_perf_warnings

  default_scope ->{ order_by(:created_at) }

  table_config :name => 'nobrainer_query_log'

  field :criteria
  field :query    
  field :options,    :type => Hash
  field :duration
  
  def criteria=(value)
    super(::RethinkDB::RPP.pp(value))
  end

  def query=(value)
    super(::RethinkDB::RPP.pp(value))
  end

  
end
