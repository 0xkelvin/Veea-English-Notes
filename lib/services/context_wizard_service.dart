import '../data/cartridges_data.dart';
import '../models/cartridge.dart';
import '../models/part_of_speech.dart';
import 'word_suggestion_service.dart';

/// Result produced by the Context & Collocation Wizard.
class ContextWizardResult {
  const ContextWizardResult({
    required this.word,
    required this.sentences,
    required this.collocations,
    required this.nuances,
    this.partOfSpeech,
  });

  final String word;
  final List<ContextSentence> sentences;
  final List<String> collocations;
  final List<NuanceItem> nuances;
  final PartOfSpeech? partOfSpeech;
}

class ContextSentence {
  const ContextSentence({
    required this.domain,
    required this.sentence,
    this.structureType,
  });

  final String domain;
  final String sentence;
  final String? structureType;
}

class NuanceItem {
  const NuanceItem({required this.synonym, required this.difference});

  final String synonym;
  final String difference;
}

/// Offline-first AI Context, Collocation, and Nuance Generator.
class ContextWizardService {
  /// Generates real-world sentences, collocations, and nuances for [rawWord].
  ///
  /// Supports optional [meaning], explicit [partOfSpeech], and [variation] seed
  /// to roll through diverse sentence structures.
  static ContextWizardResult generate(
    String rawWord, {
    String? meaning,
    PartOfSpeech? partOfSpeech,
    int variation = 0,
  }) {
    final word = rawWord.trim().toLowerCase();
    if (word.isEmpty) {
      return const ContextWizardResult(
        word: '',
        sentences: [],
        collocations: [],
        nuances: [],
      );
    }

    final capitalized = word.isNotEmpty
        ? '${word[0].toUpperCase()}${word.substring(1)}'
        : word;

    // 1. Check specialized vocabulary dictionary
    if (_specializedCorpus.containsKey(word)) {
      final base = _specializedCorpus[word]!;
      if (variation == 0) {
        return base;
      }
      // If user requested a variation/re-roll on specialized word, mix in varied templates
      final resolvedPos = base.partOfSpeech ?? detectPos(word, explicitPos: partOfSpeech);
      final dynamicVariations = _generateDynamicSentences(
        word: word,
        capitalized: capitalized,
        pos: resolvedPos,
        variation: variation,
      );
      return ContextWizardResult(
        word: word,
        sentences: dynamicVariations,
        collocations: base.collocations,
        nuances: base.nuances,
        partOfSpeech: resolvedPos,
      );
    }

    // 2. Check career cartridges (Silicon Valley Tech words, etc.)
    if (_cartridgeIndex.containsKey(word)) {
      final cw = _cartridgeIndex[word]!;
      final resolvedPos = partOfSpeech ?? cw.partOfSpeech;
      final extraSentences = _generateDynamicSentences(
        word: word,
        capitalized: capitalized,
        pos: resolvedPos,
        variation: variation,
      );

      final combinedSentences = <ContextSentence>[
        ContextSentence(
          domain: 'PR & CODE REVIEW',
          sentence: cw.prExample,
          structureType: 'Code Review Guideline',
        ),
        ContextSentence(
          domain: 'STANDUP & SPRINT',
          sentence: cw.standupExample,
          structureType: 'Engineering Update',
        ),
        if (extraSentences.isNotEmpty) extraSentences.first,
      ];

      final nuances = <NuanceItem>[
        NuanceItem(
          synonym: 'Interview Context',
          difference: cw.interviewNuance,
        ),
        NuanceItem(
          synonym: 'Professional Register',
          difference:
              'Standard vocabulary across global engineering teams and architecture documentation.',
        ),
      ];

      return ContextWizardResult(
        word: word,
        sentences: combinedSentences,
        collocations: cw.collocations,
        nuances: nuances,
        partOfSpeech: resolvedPos,
      );
    }

    // 3. Resolve Part of Speech
    final resolvedPos = detectPos(word, explicitPos: partOfSpeech);

    // 4. Generate diverse contextual sentences with varied grammatical structures
    final sentences = _generateDynamicSentences(
      word: word,
      capitalized: capitalized,
      pos: resolvedPos,
      variation: variation,
    );

    // 5. Generate collocations tailored to part of speech
    final collocations = _generateCollocations(word, resolvedPos);

    // 6. Generate contextual nuances based on grammatical category and meaning
    final nuances = _generateNuances(
      word: word,
      capitalized: capitalized,
      pos: resolvedPos,
      meaning: meaning,
    );

    return ContextWizardResult(
      word: word,
      sentences: sentences,
      collocations: collocations,
      nuances: nuances,
      partOfSpeech: resolvedPos,
    );
  }

  /// Automatically deduces the [PartOfSpeech] from cartridge data, offline
  /// dictionary, and morphological heuristics.
  static PartOfSpeech detectPos(String word, {PartOfSpeech? explicitPos}) {
    if (explicitPos != null) return explicitPos;

    final clean = word.trim().toLowerCase();

    // Check career cartridge words
    if (_cartridgeIndex.containsKey(clean)) {
      return _cartridgeIndex[clean]!.partOfSpeech;
    }

    // Check offline dictionary & fast suggestions
    final fast = WordSuggestionService.suggestFast(clean);
    if (fast?.partOfSpeech != null) {
      return fast!.partOfSpeech!;
    }

    // Check grammar heuristic
    final heuristic = WordSuggestionService.detectPartOfSpeech(clean);
    if (heuristic != null) {
      return heuristic;
    }

    // Multi-word phrases and idioms
    if (clean.contains(' ')) {
      if (clean.startsWith('in ') ||
          clean.startsWith('on ') ||
          clean.startsWith('at ') ||
          clean.startsWith('by ') ||
          clean.startsWith('for ') ||
          clean.startsWith('with ') ||
          clean.startsWith('as ') ||
          clean.startsWith('to ')) {
        return PartOfSpeech.phrase;
      }
      return PartOfSpeech.idiom;
    }

    // Default to noun for single words
    return PartOfSpeech.noun;
  }

  static String _withArticle(String word) {
    final lower = word.trim().toLowerCase();
    if (lower.isEmpty) return word;
    if (lower.startsWith('uni') ||
        lower.startsWith('use') ||
        lower.startsWith('one')) {
      return 'a $word';
    }
    if (lower.startsWith('hour') ||
        lower.startsWith('honest') ||
        lower.startsWith('honor')) {
      return 'an $word';
    }
    const vowels = {'a', 'e', 'i', 'o', 'u'};
    final article = vowels.contains(lower[0]) ? 'an' : 'a';
    return '$article $word';
  }

  static List<ContextSentence> _generateDynamicSentences({
    required String word,
    required String capitalized,
    required PartOfSpeech pos,
    required int variation,
  }) {
    final templates = _templatesForPos(pos);
    final n = templates.length;
    final articleWord = _withArticle(word);

    // Compute deterministic seed based on word characteristics and variation offset
    final seed = (word.hashCode.abs() + variation * 31);

    // Pick 3 distinct templates with different domains and syntactic structures
    final idx1 = seed % n;
    final idx2 = (seed + 3) % n;
    final idx3 = (seed + 7) % n;

    final selectedIndices = <int>[idx1];
    if (!selectedIndices.contains(idx2)) selectedIndices.add(idx2);
    if (!selectedIndices.contains(idx3)) selectedIndices.add(idx3);

    // Fallback if collisions occur
    for (var i = 0; i < n && selectedIndices.length < 3; i++) {
      if (!selectedIndices.contains(i)) selectedIndices.add(i);
    }

    return selectedIndices.map((idx) {
      final t = templates[idx];
      return ContextSentence(
        domain: t.domain,
        sentence: t.builder(word, capitalized, articleWord),
        structureType: t.structureType,
      );
    }).toList();
  }

  static List<_SentenceTemplate> _templatesForPos(PartOfSpeech pos) {
    switch (pos) {
      case PartOfSpeech.noun:
        return _nounTemplates;
      case PartOfSpeech.verb:
        return _verbTemplates;
      case PartOfSpeech.adjective:
        return _adjectiveTemplates;
      case PartOfSpeech.adverb:
        return _adverbTemplates;
      case PartOfSpeech.phrase:
      case PartOfSpeech.idiom:
        return _phraseTemplates;
      case PartOfSpeech.other:
        return _nounTemplates;
    }
  }

  static List<String> _generateCollocations(String word, PartOfSpeech pos) {
    switch (pos) {
      case PartOfSpeech.noun:
        return [
          'robust $word',
          'implement a $word',
          'core $word',
          '$word architecture',
          'key $word',
          'underlying $word',
          '$word lifecycle',
        ];
      case PartOfSpeech.verb:
        return [
          'actively $word',
          'fail to $word',
          'aim to $word',
          '$word efficiently',
          'help $word',
          'continue to $word',
          '$word securely',
        ];
      case PartOfSpeech.adjective:
        return [
          'remarkably $word',
          'highly $word',
          'remain $word',
          'increasingly $word',
          'inherently $word',
          '$word approach',
          'proven to be $word',
        ];
      case PartOfSpeech.adverb:
        return [
          '$word executed',
          'operate $word',
          '$word designed',
          'perform $word',
          'communicate $word',
          '$word integrated',
        ];
      case PartOfSpeech.phrase:
      case PartOfSpeech.idiom:
        return [
          'time to $word',
          'hesitant to $word',
          'decided to $word',
          'how to $word',
          'ready to $word',
        ];
      case PartOfSpeech.other:
        return [
          'core $word',
          'relative $word',
          'understand $word',
          'apply $word',
        ];
    }
  }

  static List<NuanceItem> _generateNuances({
    required String word,
    required String capitalized,
    required PartOfSpeech pos,
    String? meaning,
  }) {
    switch (pos) {
      case PartOfSpeech.noun:
        return [
          NuanceItem(
            synonym: 'Register & Scope',
            difference:
                '$capitalized provides precise technical or professional phrasing; in casual dialogue, simpler general nouns are often substituted.',
          ),
          NuanceItem(
            synonym: 'Common Context',
            difference:
                'Frequently paired with analytical verbs (e.g. evaluate, optimize, decouple) in architecture docs and design reviews.',
          ),
        ];
      case PartOfSpeech.verb:
        return [
          NuanceItem(
            synonym: 'Action vs General Intent',
            difference:
                '$capitalized denotes purposeful, deliberate execution; in informal contexts, phrases like "work on" or "handle" are more common.',
          ),
          NuanceItem(
            synonym: 'Usage Precision',
            difference:
                'Typically used with modal verbs (should, must) or infinitives to set clear operational standards.',
          ),
        ];
      case PartOfSpeech.adjective:
        return [
          NuanceItem(
            synonym: 'Descriptive Depth',
            difference:
                '$capitalized conveys a specific qualitative attribute; generic descriptors like "good" or "strong" lack this precision.',
          ),
          NuanceItem(
            synonym: 'Professional Tone',
            difference:
                'Carries an analytical, high-signal tone ideal for sprint retrospectives, PR reviews, and technical writing.',
          ),
        ];
      case PartOfSpeech.adverb:
        return [
          NuanceItem(
            synonym: 'Degree & Manner',
            difference:
                '$capitalized specifies exact operational manner, whereas conversational English often relies on general qualifiers like "very" or "really".',
          ),
          NuanceItem(
            synonym: 'Collocation Scope',
            difference:
                'Best positioned directly after active verbs or before past participles to describe system behavior.',
          ),
        ];
      case PartOfSpeech.phrase:
      case PartOfSpeech.idiom:
        return [
          NuanceItem(
            synonym: 'Conversational Fluency',
            difference:
                'An idiomatic expression that signals natural workplace fluency when used in standups and 1-on-1 conversations.',
          ),
          NuanceItem(
            synonym: 'Formality Guideline',
            difference:
                'Well-suited for spoken discussions and chat messages; opt for literal terminology in formal API specifications.',
          ),
        ];
      case PartOfSpeech.other:
        return [
          NuanceItem(
            synonym: 'General Usage',
            difference:
                '$capitalized should be applied where context makes its relationship to the surrounding clause unambiguous.',
          ),
        ];
    }
  }

  // --- TEMPLATE DEFINITIONS WITH DIVERSE GRAMMATICAL STRUCTURES ---

  static final List<_SentenceTemplate> _nounTemplates = [
    _SentenceTemplate(
      domain: 'WORK / SYSTEM DESIGN',
      structureType: 'Problem-Solution & Cause-Effect',
      builder: (w, cap, art) =>
          'Without a well-designed $w in place, our distributed cluster struggled to maintain low latency during traffic spikes.',
    ),
    _SentenceTemplate(
      domain: 'PR & CODE REVIEW',
      structureType: 'Imperative Quality Guideline',
      builder: (w, cap, art) =>
          'Please add integration tests to verify that the $w handles network timeouts gracefully without leaking resources.',
    ),
    _SentenceTemplate(
      domain: 'STANDUP & SPRINT',
      structureType: 'Workplace Dialogue & Progress',
      builder: (w, cap, art) =>
          'During today’s sprint sync, the backend team agreed to prioritize the $w to unblock downstream client releases.',
    ),
    _SentenceTemplate(
      domain: 'READING / ESSAY',
      structureType: 'Concessive Clause & Principle',
      builder: (w, cap, art) =>
          'Although many teams overlook the importance of $art, mastering its core principles often becomes their strongest competitive moat.',
    ),
    _SentenceTemplate(
      domain: 'PODCAST / TECH TALK',
      structureType: 'Analytical Observation',
      builder: (w, cap, art) =>
          'In the interview, the architect explained how introducing $art into their workflow fundamentally reduced production incidents.',
    ),
    _SentenceTemplate(
      domain: 'DAILY CONVERSATION',
      structureType: 'Conversational Inquiry',
      builder: (w, cap, art) =>
          'Could you walk me through how your team uses that $w during your regular deployment cycle?',
    ),
    _SentenceTemplate(
      domain: 'ARCHITECTURE & STRATEGY',
      structureType: 'Conditional Risk Mitigation',
      builder: (w, cap, art) =>
          'If we fail to properly decouple our services from this $w, scaling the platform next quarter will be risky.',
    ),
    _SentenceTemplate(
      domain: 'COLLABORATION',
      structureType: 'Reflective Workplace Insight',
      builder: (w, cap, art) =>
          'Honestly, having a clear documentation standard for each $w made onboarding new engineers remarkably smooth.',
    ),
    _SentenceTemplate(
      domain: 'RESEARCH & BENCHMARK',
      structureType: 'Passive Empirical Observation',
      builder: (w, cap, art) =>
          'Recent benchmark evaluations revealed that replacing the legacy $w yielded a 35% reduction in compute overhead.',
    ),
    _SentenceTemplate(
      domain: 'DAILY RETROSPECTIVE',
      structureType: 'Contrastive Reflection',
      builder: (w, cap, art) =>
          'I was initially hesitant about the change, but investing in that $w turned out to be our best operational decision.',
    ),
  ];

  static final List<_SentenceTemplate> _verbTemplates = [
    _SentenceTemplate(
      domain: 'WORK / ARCHITECTURE',
      structureType: 'Temporal Imperative & Precaution',
      builder: (w, cap, art) =>
          'Before rolling out this migration to production, make sure you $w all external service dependencies.',
    ),
    _SentenceTemplate(
      domain: 'PR & CODE REVIEW',
      structureType: 'Collaborative Modal Suggestion',
      builder: (w, cap, art) =>
          'We should probably $w this logic into smaller, reusable utility functions so that each path is easily testable.',
    ),
    _SentenceTemplate(
      domain: 'STANDUP & PLANNING',
      structureType: 'Conditional Milestone Target',
      builder: (w, cap, art) =>
          'If our team can successfully $w the authentication workflow by midweek, we will finish the sprint comfortably ahead of schedule.',
    ),
    _SentenceTemplate(
      domain: 'READING / LEADERSHIP',
      structureType: 'Contrastive Behavior Clause',
      builder: (w, cap, art) =>
          'While inexperienced managers often react defensively, exceptional leaders know when to pause and $w objectively.',
    ),
    _SentenceTemplate(
      domain: 'PODCAST / TECH TALK',
      structureType: 'Analytical Explanation with Infinitive',
      builder: (w, cap, art) =>
          'The engineering director noted that attempting to $w without clear baseline telemetry usually causes more problems than it solves.',
    ),
    _SentenceTemplate(
      domain: 'DAILY CONVERSATION',
      structureType: 'Collaborative Inquiry',
      builder: (w, cap, art) =>
          'Can you show me how you typically $w these edge cases when requirements shift on short notice?',
    ),
    _SentenceTemplate(
      domain: 'INCIDENT & RELIABILITY',
      structureType: 'Automated System Action',
      builder: (w, cap, art) =>
          'The monitoring daemon was programmed to $w active connections whenever memory utilization approached dangerous limits.',
    ),
    _SentenceTemplate(
      domain: 'CAREER & BEST PRACTICE',
      structureType: 'Actionable Guideline',
      builder: (w, cap, art) =>
          'When delivering critical peer feedback, always aim to $w constructive alternatives rather than simply critiquing the current approach.',
    ),
    _SentenceTemplate(
      domain: 'CASUAL WORKPLACE',
      structureType: 'Cohortative Agreement',
      builder: (w, cap, art) =>
          'Let’s sync up after lunch so we can $w on the edge-case handling before demoing the feature to stakeholders.',
    ),
    _SentenceTemplate(
      domain: 'PROBLEM SOLVING',
      structureType: 'Hypothetical Framing',
      builder: (w, cap, art) =>
          'How would you choose to $w this challenge if you had to build a fault-tolerant solution under strict latency constraints?',
    ),
  ];

  static final List<_SentenceTemplate> _adjectiveTemplates = [
    _SentenceTemplate(
      domain: 'WORK / SYSTEM DESIGN',
      structureType: 'Causal Subordinate Clause',
      builder: (w, cap, art) =>
          'Because the new message broker is fundamentally $w, transient network partitions do not trigger data loss.',
    ),
    _SentenceTemplate(
      domain: 'PR & CODE REVIEW',
      structureType: 'Direct Evaluative Praise',
      builder: (w, cap, art) =>
          'This modular refactoring makes the data layer remarkably $w and significantly simplifies onboarding for new contributors.',
    ),
    _SentenceTemplate(
      domain: 'STANDUP & PLANNING',
      structureType: 'Attributive Strategy Suggestion',
      builder: (w, cap, art) =>
          'We need to adopt $art strategy if we want to resolve these performance regressions before the upcoming launch.',
    ),
    _SentenceTemplate(
      domain: 'READING / ESSAY',
      structureType: 'Comparative Engineering Value',
      builder: (w, cap, art) =>
          'In modern software architecture, keeping the core abstractions $w is vastly more important than prematurely optimizing speed.',
    ),
    _SentenceTemplate(
      domain: 'PODCAST / INTERVIEW',
      structureType: 'Attributed Insight',
      builder: (w, cap, art) =>
          'The CTO argued that building a $w engineering culture is what ultimately allows high-growth startups to out-innovate incumbents.',
    ),
    _SentenceTemplate(
      domain: 'DAILY CONVERSATION',
      structureType: 'Retrospective Feedback',
      builder: (w, cap, art) =>
          'Everyone in the post-mortem agreed that her analysis was refreshingly $w, highlighting several overlooked factors.',
    ),
    _SentenceTemplate(
      domain: 'INCIDENT & RESILIENCE',
      structureType: 'Inverted Conditional',
      builder: (w, cap, art) =>
          'Had the failover pipeline not been sufficiently $w, the regional datacenter outage would have affected all active users.',
    ),
    _SentenceTemplate(
      domain: 'COLLABORATION',
      structureType: 'Inquisitive Evaluation',
      builder: (w, cap, art) =>
          'Do you feel that our current error-handling mechanism is $w enough to handle unpredictable third-party API downtime?',
    ),
    _SentenceTemplate(
      domain: 'LEADERSHIP & CULTURE',
      structureType: 'Principle & Consequence',
      builder: (w, cap, art) =>
          'Maintaining $art communication channel between design and engineering prevents costly misunderstandings down the road.',
    ),
    _SentenceTemplate(
      domain: 'CASUAL WORKPLACE',
      structureType: 'Conversational Reaction',
      builder: (w, cap, art) =>
          'I was pleasantly surprised by how $w the new configuration workflow felt compared to our previous setup.',
    ),
  ];

  static final List<_SentenceTemplate> _adverbTemplates = [
    _SentenceTemplate(
      domain: 'WORK / PERFORMANCE',
      structureType: 'Conditional Process Execution',
      builder: (w, cap, art) =>
          'When the background queue processes jobs $w, overall database contention drops to virtually zero.',
    ),
    _SentenceTemplate(
      domain: 'PR & CODE REVIEW',
      structureType: 'Verification Guideline',
      builder: (w, cap, art) =>
          'Please verify that the circuit breaker trips $w when upstream dependency responses exceed the timeout threshold.',
    ),
    _SentenceTemplate(
      domain: 'STANDUP & OPERATIONS',
      structureType: 'Status Report with Temporal Phrase',
      builder: (w, cap, art) =>
          'Following the staging deployment yesterday, our automated test suite finished $w without a single flaky failure.',
    ),
    _SentenceTemplate(
      domain: 'READING / ESSAY',
      structureType: 'Analytical Observation',
      builder: (w, cap, art) =>
          'The author points out that high-velocity engineering teams communicate $w, eliminating costly ambiguities in specifications.',
    ),
    _SentenceTemplate(
      domain: 'PODCAST / LEADERSHIP',
      structureType: 'Cause & Effect Principle',
      builder: (w, cap, art) =>
          'If leadership responds $w to early warning signs, small organizational frictions rarely escalate into full-blown crises.',
    ),
    _SentenceTemplate(
      domain: 'DAILY CONVERSATION',
      structureType: 'Workplace Appreciation',
      builder: (w, cap, art) =>
          'She answered the client’s tough questions so $w that everyone in the room felt reassured about our roadmap.',
    ),
    _SentenceTemplate(
      domain: 'SYSTEM RELIABILITY',
      structureType: 'Imperative Safety Rule',
      builder: (w, cap, art) =>
          'Always design worker threads to throttle down $w when downstream rate limits are detected.',
    ),
    _SentenceTemplate(
      domain: 'CASUAL WORKPLACE',
      structureType: 'Collaborative Inquiry',
      builder: (w, cap, art) =>
          'Do you think the team can execute this migration $w without scheduling an unexpected maintenance window?',
    ),
    _SentenceTemplate(
      domain: 'METHODOLOGY',
      structureType: 'Comparative Habit',
      builder: (w, cap, art) =>
          'Refactoring codebase hotspots $w in small increments consistently yields safer outcomes than massive quarterly rewrites.',
    ),
    _SentenceTemplate(
      domain: 'COLLABORATION',
      structureType: 'Reflective Remark',
      builder: (w, cap, art) =>
          'Things progressed remarkably $w once both squads agreed on the common JSON schema definitions.',
    ),
  ];

  static final List<_SentenceTemplate> _phraseTemplates = [
    _SentenceTemplate(
      domain: 'WORK / DECISION MAKING',
      structureType: 'High-Stakes Narrative',
      builder: (w, cap, art) =>
          'When unexpected production bugs emerged right before release, the team had to $w and resolve the blocker quickly.',
    ),
    _SentenceTemplate(
      domain: 'PR & CODE REVIEW',
      structureType: 'Pragmatic Engineering Advice',
      builder: (w, cap, art) =>
          'Rather than spending weeks architecting an overly complex solution, let’s just $w to fulfill our current sprint scope.',
    ),
    _SentenceTemplate(
      domain: 'STANDUP & SPRINT',
      structureType: 'Proactive Alignment',
      builder: (w, cap, art) =>
          'We set up a quick breakout session right after standup so we can $w and ensure our APIs align cleanly.',
    ),
    _SentenceTemplate(
      domain: 'READING / ESSAY',
      structureType: 'Philosophical Insight',
      builder: (w, cap, art) =>
          'A recurring takeaway from the book is that knowing when to $w separates seasoned founders from novices.',
    ),
    _SentenceTemplate(
      domain: 'PODCAST / CAREER',
      structureType: 'Interview Observation',
      builder: (w, cap, art) =>
          'The guest highlighted that engineers who learn how to $w effectively build trust much faster across departments.',
    ),
    _SentenceTemplate(
      domain: 'DAILY CONVERSATION',
      structureType: 'Casual Encouragement',
      builder: (w, cap, art) =>
          'I know the timeline feels daunting, but if we break down the tasks, we can definitely $w together.',
    ),
    _SentenceTemplate(
      domain: 'INCIDENT & TRIAGE',
      structureType: 'Post-Mortem Narrative',
      builder: (w, cap, art) =>
          'During yesterday’s critical infrastructure outage, our on-call engineers managed to $w and avert any customer data loss.',
    ),
    _SentenceTemplate(
      domain: 'CASUAL WORKPLACE',
      structureType: 'Direct Dialogue',
      builder: (w, cap, art) =>
          'Give me a shout if you’d like to $w this afternoon before we finalize the design review deck.',
    ),
    _SentenceTemplate(
      domain: 'STRATEGY & CULTURE',
      structureType: 'Concessive Decision',
      builder: (w, cap, art) =>
          'Even though delaying the decision seemed easier, the leadership team chose to $w and address the core issue head-on.',
    ),
    _SentenceTemplate(
      domain: 'PRACTICAL WISDOM',
      structureType: 'Reflective Recommendation',
      builder: (w, cap, art) =>
          'Whenever you find yourself stuck at an architectural impasse, it almost always helps to $w with a fresh pair of eyes.',
    ),
  ];

  // --- CARTRIDGE DICTIONARY INDEX ---

  static final Map<String, CartridgeWord> _cartridgeIndex = () {
    final map = <String, CartridgeWord>{};
    for (final c in CartridgesData.allCartridges) {
      for (final w in c.words) {
        map[w.word.trim().toLowerCase()] = w;
      }
    }
    return map;
  }();

  // --- CURATED SPECIALIZED CORPUS ---

  static final Map<String, ContextWizardResult> _specializedCorpus = {
    'resilient': const ContextWizardResult(
      word: 'resilient',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'WORK / ENGINEERING',
          sentence:
              'We refactored the message queue to build a resilient distributed microservice.',
          structureType: 'Purpose Clause & Architecture',
        ),
        ContextSentence(
          domain: 'READING / ESSAY',
          sentence:
              'Children who grow up overcoming adversity often become remarkably resilient adults.',
          structureType: 'Relative Clause & Observation',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Despite the sudden flight cancellation, he stayed positive and resilient.',
          structureType: 'Concessive Phrase & Dialogue',
        ),
      ],
      collocations: [
        'resilient infrastructure',
        'remain resilient',
        'remarkably resilient',
        'resilient supply chain',
        'economically resilient',
      ],
      nuances: [
        NuanceItem(
          synonym: 'tough',
          difference:
              'Tough means strong, but resilient means bouncing back after damage.',
        ),
        NuanceItem(
          synonym: 'durable',
          difference:
              'Durable applies mostly to physical objects; resilient applies to minds, code, and systems.',
        ),
      ],
    ),
    'tenacious': const ContextWizardResult(
      word: 'tenacious',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'WORK / CODING',
          sentence:
              'She showed tenacious debugging skills tracking down the race condition in the kernel.',
          structureType: 'Participial Phrase & Skill',
        ),
        ContextSentence(
          domain: 'PODCAST / NEWS',
          sentence:
              'The investigative journalist was tenacious in uncovering the financial irregularities.',
          structureType: 'Prepositional Modifier & Narrative',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'His tenacious grip on the lead carried him across the marathon finish line.',
          structureType: 'Action Verb & Metaphor',
        ),
      ],
      collocations: [
        'tenacious advocate',
        'tenacious grip',
        'tenacious defender',
        'tenacious effort',
        'tenacious memory',
      ],
      nuances: [
        NuanceItem(
          synonym: 'stubborn',
          difference:
              'Stubborn has a negative connotation (unreasonable); tenacious is positive (determined).',
        ),
        NuanceItem(
          synonym: 'persistent',
          difference:
              'Persistent simply keeps going; tenacious refuses to give up despite severe setbacks.',
        ),
      ],
    ),
    'eloquent': const ContextWizardResult(
      word: 'eloquent',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'WORK / PRESENTATION',
          sentence:
              'She gave an eloquent keynote explaining the new product vision to our stakeholders.',
          structureType: 'Participial Clause & Keynote',
        ),
        ContextSentence(
          domain: 'READING / LITERATURE',
          sentence:
              'The essay provided an eloquent defense of open-source software collaboration.',
          structureType: 'Noun Phrase Complement',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'He was so eloquent in his apology that everyone immediately forgave him.',
          structureType: 'Result Clause (So... That)',
        ),
      ],
      collocations: [
        'eloquent speaker',
        'eloquent testimony',
        'eloquent silence',
        'eloquent defense',
        'highly eloquent',
      ],
      nuances: [
        NuanceItem(
          synonym: 'fluent',
          difference:
              'Fluent means speaking smoothly without pauses; eloquent means persuasive and moving.',
        ),
        NuanceItem(
          synonym: 'articulate',
          difference:
              'Articulate means expressing ideas clearly; eloquent has emotional and aesthetic resonance.',
        ),
      ],
    ),
    'serendipity': const ContextWizardResult(
      word: 'serendipity',
      partOfSpeech: PartOfSpeech.noun,
      sentences: [
        ContextSentence(
          domain: 'WORK / DISCOVERY',
          sentence:
              'Finding that open-source library was pure serendipity that saved us two weeks of development.',
          structureType: 'Gerund Subject & Relative Clause',
        ),
        ContextSentence(
          domain: 'READING / BIOGRAPHY',
          sentence:
              'Penicillin was discovered through a famous stroke of scientific serendipity.',
          structureType: 'Passive Voice & Prepositional Phrase',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Meeting my college roommate at Tokyo airport was absolute serendipity.',
          structureType: 'Gerund Subject & Predicate Noun',
        ),
      ],
      collocations: [
        'stroke of serendipity',
        'pure serendipity',
        'happy serendipity',
        'serendipitous encounter',
      ],
      nuances: [
        NuanceItem(
          synonym: 'luck',
          difference:
              'Luck is purely random; serendipity specifically means finding something valuable when looking for something else.',
        ),
        NuanceItem(
          synonym: 'coincidence',
          difference:
              'A coincidence can be good or bad; serendipity is always a fortunate, happy discovery.',
        ),
      ],
    ),
    'ubiquitous': const ContextWizardResult(
      word: 'ubiquitous',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'WORK / TECH',
          sentence:
              'Smartphones have become so ubiquitous that mobile-first design is now an industry baseline.',
          structureType: 'Consecutive Result Clause',
        ),
        ContextSentence(
          domain: 'READING / ESSAY',
          sentence:
              'In modern knowledge work, ubiquitous connectivity has fundamentally blurred the boundary between work and home.',
          structureType: 'Complex Sentence & Observation',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Electric scooters have become ubiquitous in the city center over the past summer.',
          structureType: 'Temporal Predicate Adjective',
        ),
      ],
      collocations: [
        'ubiquitous computing',
        'almost ubiquitous',
        'become ubiquitous',
        'ubiquitous presence',
      ],
      nuances: [
        NuanceItem(
          synonym: 'common',
          difference:
              'Common means frequently occurring; ubiquitous emphasizes being seemingly everywhere at the same time.',
        ),
        NuanceItem(
          synonym: 'pervasive',
          difference:
              'Pervasive often carries a negative or invasive overtone; ubiquitous is neutral omnipresence.',
        ),
      ],
    ),
    'ambiguous': const ContextWizardResult(
      word: 'ambiguous',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'PR & CODE REVIEW',
          sentence:
              'The function return type is too ambiguous; let’s use a sealed class to make error states explicit.',
          structureType: 'Compound Recommendation',
        ),
        ContextSentence(
          domain: 'STANDUP & SPRINT',
          sentence:
              'Because the ticket requirements were ambiguous, we scheduled a quick spike with the product manager.',
          structureType: 'Causal Subordinate Clause',
        ),
        ContextSentence(
          domain: 'READING / LEADERSHIP',
          sentence:
              'Effective leaders maintain calm and provide clarity even when operating in deeply ambiguous environments.',
          structureType: 'Concessive Adverbial Clause',
        ),
      ],
      collocations: [
        'ambiguous requirement',
        'remain ambiguous',
        'highly ambiguous',
        'resolve ambiguous',
      ],
      nuances: [
        NuanceItem(
          synonym: 'vague',
          difference:
              'Vague lacks specific detail; ambiguous can be interpreted in two or more specific, conflicting ways.',
        ),
        NuanceItem(
          synonym: 'confusing',
          difference:
              'Confusing describes the listener’s feeling; ambiguous describes the objective dual-meaning of the text.',
        ),
      ],
    ),
    'pivotal': const ContextWizardResult(
      word: 'pivotal',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'WORK / ARCHITECTURE',
          sentence:
              'Choosing an event-driven model was a pivotal architecture decision that enabled horizontal scaling.',
          structureType: 'Gerund Subject & Relative Clause',
        ),
        ContextSentence(
          domain: 'READING / BIOGRAPHY',
          sentence:
              'Securing that seed investment proved to be a pivotal turning point in the company’s trajectory.',
          structureType: 'Linking Verb & Predicate Nominal',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Her mentorship played a pivotal role in my transition from QA into backend engineering.',
          structureType: 'Collocational Idiom (Played a Pivotal Role)',
        ),
      ],
      collocations: [
        'pivotal role',
        'pivotal moment',
        'pivotal decision',
        'pivotal turning point',
      ],
      nuances: [
        NuanceItem(
          synonym: 'crucial',
          difference:
              'Crucial stresses urgency and severe necessity; pivotal stresses acting as the hinge that changes everything.',
        ),
        NuanceItem(
          synonym: 'important',
          difference:
              'Important simply indicates value; pivotal implies a structural redirection of the entire outcome.',
        ),
      ],
    ),
    'coherent': const ContextWizardResult(
      word: 'coherent',
      partOfSpeech: PartOfSpeech.adjective,
      sentences: [
        ContextSentence(
          domain: 'PR & CODE REVIEW',
          sentence:
              'Extracting the billing calculator into its own domain service makes the overall module far more coherent.',
          structureType: 'Gerund Subject & Result Clause',
        ),
        ContextSentence(
          domain: 'READING / ESSAY',
          sentence:
              'A coherent technical strategy empowers autonomous squads to move fast without stepping on each other’s toes.',
          structureType: 'Simple Declarative with Metaphor',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Her walkthrough of the incident timeline was clear, structured, and remarkably coherent.',
          structureType: 'Series of Predicate Adjectives',
        ),
      ],
      collocations: [
        'coherent strategy',
        'remain coherent',
        'coherent explanation',
        'remarkably coherent',
      ],
      nuances: [
        NuanceItem(
          synonym: 'logical',
          difference:
              'Logical means following sound deductive rules; coherent means all constituent parts fit together seamlessly into a whole.',
        ),
        NuanceItem(
          synonym: 'consistent',
          difference:
              'Consistent means not contradicting across time; coherent means holding together as a unified whole right now.',
        ),
      ],
    ),
  };
}

class _SentenceTemplate {
  const _SentenceTemplate({
    required this.domain,
    required this.structureType,
    required this.builder,
  });

  final String domain;
  final String structureType;
  final String Function(String word, String capitalized, String withArticle)
  builder;
}
