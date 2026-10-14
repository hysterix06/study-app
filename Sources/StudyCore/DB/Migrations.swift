import Foundation

/// Forward-only numbered migrations, tracked with PRAGMA user_version (§3.4). Owned by the app;
/// the MCP server only checks the version.
public enum Migrations {
    public static var currentVersion: Int { all.count }

    public static let all: [String] = [v1, v2, v3, v4, v5, v6, v7]

    /// Runs every migration after the database's version, up to `target` (tests stop early to build old databases).
    ///
    /// Rebuilding a table (create a copy, copy the rows, drop, rename) must not cascade: with foreign keys on, the drop
    /// would delete every child row (a material's chunks, sources and questions). So foreign keys go off for the run,
    /// which only works outside a transaction, and each migration checks that it broke no reference before it commits.
    public static func migrate(_ db: Database, upTo target: Int = all.count) throws {
        let version = db.userVersion
        guard version < target else { return }
        try db.execute("PRAGMA foreign_keys=OFF")
        defer { _ = try? db.execute("PRAGMA foreign_keys=ON") }
        for (i, sql) in all.enumerated() where i >= version && i < target {
            try db.transaction {
                let before = try db.query("PRAGMA foreign_key_check").count
                try db.executeScript(sql)
                let after = try db.query("PRAGMA foreign_key_check").count
                if after > before {
                    throw DBError.step("Migration \(i + 1) would leave \(after - before) broken references, so nothing was changed.",
                                       sql: "PRAGMA foreign_key_check")
                }
                try db.execute("PRAGMA user_version = \(i + 1)")
            }
        }
    }

    public static func check(_ db: Database) throws {
        let v = db.userVersion
        if v != currentVersion { throw DBError.schemaMismatch(found: v, expected: currentVersion) }
    }

    static let v1 = """
    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE TABLE terms (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      is_current INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE term_breaks (
      id INTEGER PRIMARY KEY,
      term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      label TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE courses (
      id INTEGER PRIMARY KEY,
      term_id INTEGER NOT NULL REFERENCES terms(id),
      code TEXT,
      name TEXT NOT NULL,
      instructor TEXT,
      color TEXT NOT NULL DEFAULT 'slate',
      aliases TEXT,
      kind TEXT NOT NULL DEFAULT 'lecture' CHECK (kind IN ('lecture','practical','seminar','placement','online')),
      grade_scale TEXT NOT NULL DEFAULT 'percent' CHECK (grade_scale IN ('percent','ten','twenty','swiss')),
      target_grade REAL,
      pass_mark REAL,
      moodle_id INTEGER,
      archived INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE class_patterns (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
      start_time TEXT NOT NULL,
      end_time TEXT NOT NULL,
      location TEXT,
      valid_from TEXT NOT NULL,
      valid_to TEXT NOT NULL,
      timezone TEXT NOT NULL,
      external_uid TEXT,
      user_modified INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX class_patterns_external ON class_patterns(external_uid);

    CREATE TABLE class_exceptions (
      id INTEGER PRIMARY KEY,
      pattern_id INTEGER NOT NULL REFERENCES class_patterns(id) ON DELETE CASCADE,
      original_date TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('cancel','modify')),
      new_date TEXT, new_start_time TEXT, new_end_time TEXT, new_location TEXT,
      note TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      UNIQUE (pattern_id, original_date)
    );

    CREATE TABLE calendar_sources (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('file','feed')),
      role TEXT NOT NULL DEFAULT 'school' CHECK (role IN ('school','busy')),
      keychain_account TEXT,
      last_synced_at TEXT,
      last_status TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE events (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      title TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'event' CHECK (kind IN ('class','event','busy')),
      start_at TEXT NOT NULL,
      end_at TEXT,
      all_day INTEGER NOT NULL DEFAULT 0,
      location TEXT,
      notes TEXT,
      canceled INTEGER NOT NULL DEFAULT 0,
      source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','ics','moodle')),
      calendar_source_id INTEGER REFERENCES calendar_sources(id) ON DELETE CASCADE,
      external_uid TEXT,
      user_modified INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE UNIQUE INDEX events_external ON events(source, external_uid) WHERE external_uid IS NOT NULL;
    CREATE INDEX events_start ON events(start_at);

    CREATE TABLE materials (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      suggested_course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      title TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('slides','pdf','doc','text','image')),
      role TEXT NOT NULL DEFAULT 'lecture'
        CHECK (role IN ('lecture','reading','syllabus','rubric','brief','past_exam','other')),
      original_filename TEXT,
      stored_path TEXT,
      assets_path TEXT,
      content_hash TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'inbox' CHECK (status IN ('inbox','ready','needs_ocr','failed')),
      status_detail TEXT,
      page_count INTEGER,
      processed_at TEXT,
      external_uid TEXT,
      imported_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX materials_external ON materials(external_uid);

    CREATE TABLE chunks (
      id INTEGER PRIMARY KEY,
      material_id INTEGER NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL,
      locator TEXT NOT NULL,
      heading TEXT,
      text_md TEXT NOT NULL,
      notes_md TEXT,
      extra_md TEXT,
      image_count INTEGER NOT NULL DEFAULT 0,
      images TEXT,
      ocr INTEGER NOT NULL DEFAULT 0,
      token_estimate INTEGER NOT NULL,
      UNIQUE (material_id, ordinal)
    );

    CREATE TABLE assignments (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE CASCADE,  -- NULL only while proposed and unmatched
      title TEXT NOT NULL,
      description TEXT,
      kind TEXT NOT NULL DEFAULT 'assignment'
        CHECK (kind IN ('assignment','report','project','case','presentation','quiz','exam','lab','reading','other')),
      due_at TEXT,
      status TEXT NOT NULL DEFAULT 'not_started'
        CHECK (status IN ('not_started','in_progress','submitted','graded')),
      weight_pct REAL,
      est_hours REAL,
      score REAL,
      max_score REAL,
      min_pass_pct REAL,
      group_members TEXT,
      rubric_material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      confirmed INTEGER NOT NULL DEFAULT 1,
      dismissed INTEGER NOT NULL DEFAULT 0,
      source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','ics','claude','moodle')),
      source_material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      source_locator TEXT,
      external_uid TEXT,
      url TEXT,
      submitted_at TEXT,
      user_modified INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX assignments_due ON assignments(due_at);
    CREATE INDEX assignments_course_status ON assignments(course_id, status);
    CREATE UNIQUE INDEX assignments_external ON assignments(source, external_uid) WHERE external_uid IS NOT NULL;

    CREATE TABLE concepts (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      first_material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      name TEXT NOT NULL,
      definition TEXT NOT NULL,
      importance INTEGER NOT NULL CHECK (importance BETWEEN 1 AND 3),
      created_by TEXT NOT NULL DEFAULT 'claude' CHECK (created_by IN ('claude','user')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      UNIQUE (course_id, name COLLATE NOCASE)
    );

    CREATE TABLE concept_sources (
      concept_id INTEGER NOT NULL REFERENCES concepts(id) ON DELETE CASCADE,
      material_id INTEGER NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
      chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
      PRIMARY KEY (concept_id, chunk_id)
    );
    CREATE INDEX concept_sources_material ON concept_sources(material_id);

    CREATE TABLE concept_links (
      id INTEGER PRIMARY KEY,
      from_concept_id INTEGER NOT NULL REFERENCES concepts(id) ON DELETE CASCADE,
      to_concept_id INTEGER NOT NULL REFERENCES concepts(id) ON DELETE CASCADE,
      relation TEXT NOT NULL CHECK (relation IN ('part_of','causes','contrasts','example_of','prerequisite')),
      UNIQUE (from_concept_id, to_concept_id, relation)
    );

    CREATE TABLE questions (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      material_id INTEGER NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
      concept_id INTEGER REFERENCES concepts(id) ON DELETE SET NULL,
      kind TEXT NOT NULL CHECK (kind IN ('recall','explain','apply','compare','calculate')),
      prompt TEXT NOT NULL,
      answer_key TEXT NOT NULL,
      source_chunk_ids TEXT NOT NULL,
      difficulty INTEGER NOT NULL DEFAULT 2 CHECK (difficulty BETWEEN 1 AND 3),
      created_by TEXT NOT NULL DEFAULT 'claude' CHECK (created_by IN ('claude','user')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX questions_material ON questions(material_id);

    CREATE TABLE cards (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      concept_id INTEGER REFERENCES concepts(id) ON DELETE SET NULL,
      question_id INTEGER REFERENCES questions(id) ON DELETE SET NULL,
      front TEXT NOT NULL,
      back TEXT NOT NULL,
      source_locators TEXT,
      due TEXT NOT NULL,
      state INTEGER NOT NULL DEFAULT 0,
      fsrs_json TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('proposed','active','suspended')),
      created_by TEXT NOT NULL DEFAULT 'user' CHECK (created_by IN ('claude','user')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX cards_due ON cards(due) WHERE status = 'active';

    CREATE TABLE card_reviews (
      id INTEGER PRIMARY KEY,
      card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
      reviewed_at TEXT NOT NULL,
      rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
      rated_by TEXT NOT NULL DEFAULT 'user' CHECK (rated_by IN ('user')),
      state_before INTEGER,
      elapsed_days REAL,
      duration_ms INTEGER
    );
    CREATE INDEX card_reviews_card ON card_reviews(card_id);

    CREATE TABLE notes (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
      kind TEXT NOT NULL CHECK (kind IN ('cornell_sheet','gap_report','summary','session_log','user_note',
                                         'handwriting_review','rubric_check','practice_set','exam_patterns')),
      title TEXT NOT NULL,
      content_md TEXT NOT NULL,
      data_json TEXT,
      created_by TEXT NOT NULL CHECK (created_by IN ('claude','user')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE handwriting_captures (
      id INTEGER PRIMARY KEY,
      material_id INTEGER NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
      image_path TEXT NOT NULL,
      ocr_text TEXT NOT NULL,
      coverage_json TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE study_sessions (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
      kind TEXT NOT NULL CHECK (kind IN ('process','recall','feynman','quiz','review','free','handwriting')),
      started_at TEXT NOT NULL,
      ended_at TEXT,
      summary TEXT,
      weak_concept_ids TEXT,
      items_total INTEGER,
      items_correct INTEGER,
      created_by TEXT NOT NULL DEFAULT 'user' CHECK (created_by IN ('user','claude')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE study_blocks (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
      planned_start TEXT NOT NULL,
      planned_minutes INTEGER NOT NULL,
      focus TEXT,
      status TEXT NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','planned','done','skipped','dismissed')),
      created_by TEXT NOT NULL DEFAULT 'user' CHECK (created_by IN ('user','claude','planner')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX study_blocks_start ON study_blocks(planned_start);

    CREATE TABLE conflicts (
      id INTEGER PRIMARY KEY,
      entity TEXT NOT NULL,
      entity_id INTEGER NOT NULL,
      source TEXT NOT NULL,
      summary TEXT NOT NULL,
      incoming_json TEXT NOT NULL,
      resolved_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE sync_map (
      entity TEXT NOT NULL,
      entity_key TEXT NOT NULL,
      target TEXT NOT NULL,
      target_id TEXT NOT NULL,
      fingerprint TEXT NOT NULL,
      PRIMARY KEY (entity, entity_key, target)
    );

    CREATE TABLE audit_log (
      id INTEGER PRIMARY KEY,
      at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      actor TEXT NOT NULL CHECK (actor IN ('app','mcp','sync')),
      action TEXT NOT NULL,
      entity TEXT,
      entity_id INTEGER,
      detail TEXT
    );
    """

    static let v2 = """
    ALTER TABLE courses ADD COLUMN short_name TEXT;
    """

    /// Recently Deleted: every delete saves the rows it removes (and the links it clears) so it can be restored exactly.
    static let v3 = """
    CREATE TABLE trash (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      entity_id INTEGER,
      label TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      batch_id TEXT
    );
    CREATE INDEX trash_deleted_at ON trash(deleted_at);
    """

    /// Claude jobs: one queue and one Activity log for every Claude task, in either run mode.
    static let v4 = """
    CREATE TABLE claude_jobs (
      id INTEGER PRIMARY KEY,
      task TEXT NOT NULL,
      args_json TEXT NOT NULL DEFAULT '{}',
      object_kind TEXT,
      object_id INTEGER,
      label TEXT NOT NULL,
      mode TEXT NOT NULL CHECK (mode IN ('automatic','desktop')),
      state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','handed_off','waiting','done','failed','canceled')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      started_at TEXT,
      finished_at TEXT,
      result_summary TEXT,
      results_json TEXT NOT NULL DEFAULT '{}',
      error TEXT
    );
    CREATE INDEX claude_jobs_state ON claude_jobs(state);
    """

    /// AI everywhere: the built-in AI writes as actor 'ai'; jobs record the engine, tokens and cost and can run as an
    /// in-app chat or a copy-and-paste handoff; the MCP server records which apps use it; chats and usage live locally.
    static let v5 = """
    CREATE TABLE audit_log_v5 (
      id INTEGER PRIMARY KEY,
      at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      actor TEXT NOT NULL CHECK (actor IN ('app','mcp','sync','ai')),
      action TEXT NOT NULL,
      entity TEXT,
      entity_id INTEGER,
      detail TEXT
    );
    INSERT INTO audit_log_v5 SELECT id, at, actor, action, entity, entity_id, detail FROM audit_log;
    DROP TABLE audit_log;
    ALTER TABLE audit_log_v5 RENAME TO audit_log;

    CREATE TABLE claude_jobs_v5 (
      id INTEGER PRIMARY KEY,
      task TEXT NOT NULL,
      args_json TEXT NOT NULL DEFAULT '{}',
      object_kind TEXT,
      object_id INTEGER,
      label TEXT NOT NULL,
      mode TEXT NOT NULL CHECK (mode IN ('automatic','desktop','chat','paste')),
      engine TEXT,
      state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','handed_off','waiting','done','failed','canceled')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      started_at TEXT,
      finished_at TEXT,
      result_summary TEXT,
      results_json TEXT NOT NULL DEFAULT '{}',
      error TEXT,
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      cost_usd REAL
    );
    INSERT INTO claude_jobs_v5(id, task, args_json, object_kind, object_id, label, mode, engine, state, created_at, started_at, finished_at, result_summary, results_json, error)
      SELECT id, task, args_json, object_kind, object_id, label, mode,
             CASE mode WHEN 'automatic' THEN 'cli.claude' ELSE 'app.claude-desktop' END,
             state, created_at, started_at, finished_at, result_summary, results_json, error FROM claude_jobs;
    DROP TABLE claude_jobs;
    ALTER TABLE claude_jobs_v5 RENAME TO claude_jobs;
    CREATE INDEX claude_jobs_state ON claude_jobs(state);

    CREATE TABLE mcp_clients (
      name TEXT PRIMARY KEY,
      version TEXT,
      protocol TEXT,
      first_seen TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      last_seen TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE ai_usage (
      id INTEGER PRIMARY KEY,
      at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      provider TEXT NOT NULL,
      model TEXT NOT NULL,
      job_id INTEGER,
      chat_id INTEGER,
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      cost_usd REAL
    );
    CREATE INDEX ai_usage_at ON ai_usage(at);

    CREATE TABLE ai_chats (
      id INTEGER PRIMARY KEY,
      task TEXT,
      args_json TEXT NOT NULL DEFAULT '{}',
      object_kind TEXT,
      object_id INTEGER,
      job_id INTEGER,
      title TEXT NOT NULL,
      engine TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE ai_messages (
      id INTEGER PRIMARY KEY,
      chat_id INTEGER NOT NULL REFERENCES ai_chats(id) ON DELETE CASCADE,
      role TEXT NOT NULL CHECK (role IN ('user','assistant','tool','event')),
      text TEXT NOT NULL DEFAULT '',
      data_json TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX ai_messages_chat ON ai_messages(chat_id, id);
    """

    /// Notebook → Path → Session → Review. Course files become signals: practice problems and class examples get their
    /// own roles, any file can be set aside ("Not used"), and Moodle's section names are kept for sorting. Each course
    /// gets a path of units and topics with a handwritten-notebook guide, lessons and a practice bank; sessions remember
    /// their step; jobs gain lanes, priorities and retries.
    static let v6 = """
    CREATE TABLE materials_v6 (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      suggested_course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      title TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('slides','pdf','doc','text','image')),
      role TEXT NOT NULL DEFAULT 'lecture'
        CHECK (role IN ('lecture','reading','practice','example','syllabus','rubric','brief','past_exam','other')),
      role_source TEXT NOT NULL DEFAULT 'auto' CHECK (role_source IN ('legacy','auto','moodle','ai','user')),
      role_confidence REAL,
      sort_reason TEXT,
      excluded INTEGER NOT NULL DEFAULT 0,
      section_name TEXT,
      module_name TEXT,
      pairs_with INTEGER,
      taught_on TEXT,
      read_state TEXT NOT NULL DEFAULT 'pending' CHECK (read_state IN ('pending','done','skipped','failed')),
      read_at TEXT,
      read_engine TEXT,
      original_filename TEXT,
      stored_path TEXT,
      assets_path TEXT,
      content_hash TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'inbox' CHECK (status IN ('inbox','ready','needs_ocr','failed')),
      status_detail TEXT,
      page_count INTEGER,
      processed_at TEXT,
      external_uid TEXT,
      imported_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    INSERT INTO materials_v6(id, course_id, suggested_course_id, title, kind, role, role_source, original_filename, stored_path,
                             assets_path, content_hash, status, status_detail, page_count, processed_at, external_uid,
                             imported_at, created_at, updated_at)
      SELECT id, course_id, suggested_course_id, title, kind, role, 'legacy', original_filename, stored_path,
             assets_path, content_hash, status, status_detail, page_count, processed_at, external_uid,
             imported_at, created_at, updated_at FROM materials;
    DROP TABLE materials;
    ALTER TABLE materials_v6 RENAME TO materials;
    CREATE INDEX materials_external ON materials(external_uid);
    CREATE INDEX materials_course_role ON materials(course_id, role, excluded);

    CREATE TABLE course_paths (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL UNIQUE REFERENCES courses(id) ON DELETE CASCADE,
      tier TEXT NOT NULL DEFAULT 'skeleton' CHECK (tier IN ('skeleton','basic','full')),
      built_with TEXT,
      approach_md TEXT,
      angles_md TEXT,
      resources_json TEXT,
      version INTEGER NOT NULL DEFAULT 1,
      signals_hash TEXT,
      stale INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE path_units (
      id INTEGER PRIMARY KEY,
      path_id INTEGER NOT NULL REFERENCES course_paths(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL,
      title TEXT NOT NULL,
      summary TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX path_units_path ON path_units(path_id, ordinal);

    CREATE TABLE path_topics (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      unit_id INTEGER REFERENCES path_units(id) ON DELETE SET NULL,
      ordinal INTEGER NOT NULL DEFAULT 0,
      key TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT,
      objectives_json TEXT NOT NULL DEFAULT '[]',
      prereq_ids_json TEXT NOT NULL DEFAULT '[]',
      est_minutes INTEGER NOT NULL DEFAULT 25 CHECK (est_minutes BETWEEN 5 AND 240),
      emphasis INTEGER NOT NULL DEFAULT 1 CHECK (emphasis BETWEEN 0 AND 3),
      beyond_course INTEGER NOT NULL DEFAULT 0,
      retired INTEGER NOT NULL DEFAULT 0,
      user_state TEXT CHECK (user_state IN ('known','hidden')),
      mastery TEXT NOT NULL DEFAULT 'new' CHECK (mastery IN ('new','familiar','learning','practiced','solid','refresh')),
      mastery_at TEXT,
      last_studied_at TEXT,
      notebook_written_at TEXT,
      notebook_page TEXT,
      created_by TEXT NOT NULL DEFAULT 'claude' CHECK (created_by IN ('claude','user','app')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE UNIQUE INDEX path_topics_key ON path_topics(course_id, key);
    CREATE INDEX path_topics_unit ON path_topics(unit_id, ordinal);

    CREATE TABLE topic_notebook (
      topic_id INTEGER PRIMARY KEY REFERENCES path_topics(id) ON DELETE CASCADE,
      terms_json TEXT NOT NULL DEFAULT '[]',
      diagrams_json TEXT NOT NULL DEFAULT '[]',
      formulas_json TEXT NOT NULL DEFAULT '[]',
      links_json TEXT NOT NULL DEFAULT '[]',
      tier TEXT NOT NULL CHECK (tier IN ('skeleton','basic','full')),
      generated_by TEXT NOT NULL,
      stale INTEGER NOT NULL DEFAULT 0,
      version INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE topic_lessons (
      topic_id INTEGER PRIMARY KEY REFERENCES path_topics(id) ON DELETE CASCADE,
      tier TEXT NOT NULL CHECK (tier IN ('skeleton','basic','full')),
      pre_question TEXT,
      sections_json TEXT NOT NULL DEFAULT '[]',
      checks_json TEXT NOT NULL DEFAULT '[]',
      cards_json TEXT NOT NULL DEFAULT '[]',
      explain_prompt TEXT,
      est_minutes INTEGER,
      generated_by TEXT NOT NULL,
      stale INTEGER NOT NULL DEFAULT 0,
      version INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE material_scans (
      material_id INTEGER NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('outline','syllabus','practice','exam')),
      result_json TEXT NOT NULL,
      engine TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      PRIMARY KEY (material_id, kind)
    );

    CREATE TABLE topic_coverage (
      topic_id INTEGER NOT NULL REFERENCES path_topics(id) ON DELETE CASCADE,
      material_id INTEGER NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
      chunk_ids_json TEXT NOT NULL DEFAULT '[]',
      emphasis INTEGER NOT NULL DEFAULT 1,
      source TEXT NOT NULL DEFAULT 'scan' CHECK (source IN ('scan','builder','user')),
      PRIMARY KEY (topic_id, material_id)
    );
    CREATE INDEX topic_coverage_material ON topic_coverage(material_id);

    CREATE TABLE practice_items (
      id INTEGER PRIMARY KEY,
      course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      topic_id INTEGER REFERENCES path_topics(id) ON DELETE SET NULL,
      topic_label TEXT,
      source TEXT NOT NULL CHECK (source IN ('course','generated')),
      material_id INTEGER REFERENCES materials(id) ON DELETE CASCADE,
      chunk_ids_json TEXT NOT NULL DEFAULT '[]',
      locator TEXT,
      number TEXT,
      kind TEXT NOT NULL DEFAULT 'short'
        CHECK (kind IN ('calculate','short','explain','apply','compare','mcq','essay','proof','case','other')),
      prompt_md TEXT NOT NULL,
      solution_md TEXT,
      hints_json TEXT NOT NULL DEFAULT '[]',
      difficulty INTEGER NOT NULL DEFAULT 2 CHECK (difficulty BETWEEN 1 AND 3),
      exam_style INTEGER NOT NULL DEFAULT 0,
      marks REAL,
      created_by TEXT NOT NULL DEFAULT 'claude' CHECK (created_by IN ('claude','user','app')),
      legacy_question_id INTEGER,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX practice_items_topic ON practice_items(topic_id);
    CREATE INDEX practice_items_course ON practice_items(course_id, source);
    CREATE INDEX practice_items_material ON practice_items(material_id);

    CREATE TABLE assessment_topics (
      assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
      topic_id INTEGER NOT NULL REFERENCES path_topics(id) ON DELETE CASCADE,
      source TEXT NOT NULL DEFAULT 'auto' CHECK (source IN ('builder','syllabus','auto','user')),
      PRIMARY KEY (assignment_id, topic_id)
    );
    CREATE INDEX assessment_topics_topic ON assessment_topics(topic_id);

    CREATE TABLE study_sessions_v6 (
      id INTEGER PRIMARY KEY,
      course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
      material_id INTEGER REFERENCES materials(id) ON DELETE SET NULL,
      assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
      topic_id INTEGER REFERENCES path_topics(id) ON DELETE SET NULL,
      kind TEXT NOT NULL
        CHECK (kind IN ('process','recall','feynman','quiz','review','free','handwriting','notebook','topic','exam_prep')),
      mode TEXT CHECK (mode IN ('quick','standard','deep')),
      step TEXT,
      progress_json TEXT,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      summary TEXT,
      weak_concept_ids TEXT,
      items_total INTEGER,
      items_correct INTEGER,
      created_by TEXT NOT NULL DEFAULT 'user' CHECK (created_by IN ('user','claude')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    INSERT INTO study_sessions_v6(id, course_id, material_id, assignment_id, kind, started_at, ended_at, summary,
                                  weak_concept_ids, items_total, items_correct, created_by, created_at)
      SELECT id, course_id, material_id, assignment_id, kind, started_at, ended_at, summary,
             weak_concept_ids, items_total, items_correct, created_by, created_at FROM study_sessions;
    DROP TABLE study_sessions;
    ALTER TABLE study_sessions_v6 RENAME TO study_sessions;
    CREATE INDEX study_sessions_topic ON study_sessions(topic_id);
    CREATE INDEX study_sessions_open ON study_sessions(ended_at, kind);

    CREATE TABLE practice_attempts (
      id INTEGER PRIMARY KEY,
      item_id INTEGER NOT NULL REFERENCES practice_items(id) ON DELETE CASCADE,
      session_id INTEGER REFERENCES study_sessions(id) ON DELETE SET NULL,
      attempted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      answer_text TEXT,
      self_rating TEXT NOT NULL CHECK (self_rating IN ('got','partly','missed')),
      rated_by TEXT NOT NULL DEFAULT 'user' CHECK (rated_by IN ('user')),
      ai_feedback_md TEXT,
      ai_verdict TEXT,
      duration_ms INTEGER
    );
    CREATE INDEX practice_attempts_item ON practice_attempts(item_id);

    CREATE TABLE topic_checks (
      id INTEGER PRIMARY KEY,
      topic_id INTEGER NOT NULL REFERENCES path_topics(id) ON DELETE CASCADE,
      session_id INTEGER REFERENCES study_sessions(id) ON DELETE SET NULL,
      kind TEXT NOT NULL CHECK (kind IN ('notebook_review','explain')),
      rating TEXT NOT NULL CHECK (rating IN ('solid','shaky','nailed','mostly','not_yet')),
      rated_by TEXT NOT NULL DEFAULT 'user' CHECK (rated_by IN ('user')),
      answer_text TEXT,
      ai_feedback_md TEXT,
      at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX topic_checks_topic ON topic_checks(topic_id, kind);

    ALTER TABLE cards ADD COLUMN topic_id INTEGER REFERENCES path_topics(id) ON DELETE SET NULL;
    CREATE INDEX cards_topic ON cards(topic_id);

    ALTER TABLE claude_jobs ADD COLUMN lane TEXT NOT NULL DEFAULT 'everyday';
    ALTER TABLE claude_jobs ADD COLUMN priority INTEGER NOT NULL DEFAULT 50;
    ALTER TABLE claude_jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE claude_jobs ADD COLUMN engines_tried TEXT NOT NULL DEFAULT '[]';
    ALTER TABLE claude_jobs ADD COLUMN not_before TEXT;
    ALTER TABLE claude_jobs ADD COLUMN course_id INTEGER;

    -- The old slide questions become practice (they keep their source slides); topics are linked later.
    INSERT INTO practice_items(course_id, source, material_id, chunk_ids_json, kind, prompt_md, solution_md, difficulty,
                               created_by, legacy_question_id, created_at, updated_at)
      SELECT course_id, 'generated', material_id, source_chunk_ids, CASE kind WHEN 'recall' THEN 'short' ELSE kind END,
             prompt, answer_key, difficulty, created_by, id, created_at, updated_at FROM questions;

    -- Files skipped in the old Inbox are files the student set aside: "Not used".
    UPDATE materials SET excluded = 1, role_source = 'user', read_state = 'skipped'
      WHERE id IN (SELECT CAST(value AS INTEGER) FROM json_each(
        COALESCE((SELECT value FROM settings WHERE key = 'inbox_skipped_materials'), '[]')));
    DELETE FROM settings WHERE key = 'inbox_skipped_materials';
    """

    /// The student steers AI work: a job can be paused (it waits until they resume it), and every job keeps a log of
    /// what it did (each request and reply, progress, and the student's own pauses), so the Activity window can show it.
    static let v7 = """
    ALTER TABLE claude_jobs ADD COLUMN paused INTEGER NOT NULL DEFAULT 0;

    CREATE TABLE job_events (
      id INTEGER PRIMARY KEY,
      job_id INTEGER NOT NULL REFERENCES claude_jobs(id) ON DELETE CASCADE,
      at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      kind TEXT NOT NULL,
      text TEXT NOT NULL,
      file TEXT
    );
    CREATE INDEX job_events_job ON job_events(job_id, id);
    """
}
