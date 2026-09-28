import Foundation

/// Forward-only numbered migrations, tracked with PRAGMA user_version (§3.4). Owned by the app;
/// the MCP server only checks the version.
public enum Migrations {
    public static var currentVersion: Int { all.count }

    public static let all: [String] = [v1]

    public static func migrate(_ db: Database) throws {
        let version = db.userVersion
        guard version < all.count else { return }
        for (i, sql) in all.enumerated() where i >= version {
            try db.transaction {
                try db.executeScript(sql)
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
}
