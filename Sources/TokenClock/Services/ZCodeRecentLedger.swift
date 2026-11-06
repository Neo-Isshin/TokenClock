import Foundation

extension ZCodeLedger {
    /// Narrow the keys, not their attempt history. A newer completed attempt
    /// outside the time window must still supersede an older in-window row.
    /// The daily accounting query deliberately keeps its original all-time CTE.
    static let recentCompletedRowsSQL = """
    WITH recent_keys AS (
      SELECT DISTINCT logical_request_id FROM model_usage
      WHERE status = 'completed' AND completed_at >= ?1 AND completed_at <= ?2
        AND logical_request_id IS NOT NULL
    ), latest_completed AS (
      SELECT rowid AS ledger_rowid,
        ROW_NUMBER() OVER (
          PARTITION BY logical_request_id,
            CASE WHEN logical_request_id IS NULL OR attempt_index IS NULL THEN rowid ELSE 0 END
          ORDER BY attempt_index DESC, rowid DESC
        ) AS completion_rank
      FROM model_usage WHERE status = 'completed' AND (
        logical_request_id IN (SELECT logical_request_id FROM recent_keys)
        OR (logical_request_id IS NULL AND completed_at >= ?1 AND completed_at <= ?2)
      )
    )
    """
}
