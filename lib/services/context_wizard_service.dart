/// Result produced by the Context & Collocation Wizard.
class ContextWizardResult {
  const ContextWizardResult({
    required this.word,
    required this.sentences,
    required this.collocations,
    required this.nuances,
  });

  final String word;
  final List<ContextSentence> sentences;
  final List<String> collocations;
  final List<NuanceItem> nuances;
}

class ContextSentence {
  const ContextSentence({
    required this.domain,
    required this.sentence,
  });

  final String domain; // e.g. 'WORK / CODE', 'READING / PODCAST', 'DAILY / CONVERSATION'
  final String sentence;
}

class NuanceItem {
  const NuanceItem({
    required this.synonym,
    required this.difference,
  });

  final String synonym;
  final String difference;
}

/// Offline-first AI Context, Collocation, and Nuance Generator.
class ContextWizardService {
  static ContextWizardResult generate(String rawWord, {String? meaning}) {
    final word = rawWord.trim().toLowerCase();
    if (word.isEmpty) {
      return const ContextWizardResult(
        word: '',
        sentences: [],
        collocations: [],
        nuances: [],
      );
    }

    // 1. Check specialized vocabulary dictionary
    if (_specializedCorpus.containsKey(word)) {
      return _specializedCorpus[word]!;
    }

    // 2. Generate contextual sentences from linguistic templates
    final capitalized = word.isNotEmpty
        ? '${word[0].toUpperCase()}${word.substring(1)}'
        : word;

    final sentences = [
      ContextSentence(
        domain: 'WORK / ENGINEERING',
        sentence:
            'Our architecture is designed to be highly $word under heavy production traffic.',
      ),
      ContextSentence(
        domain: 'READING / PODCAST',
        sentence:
            'The author argued that a $word mindset is what separates great leaders from the rest.',
      ),
      ContextSentence(
        domain: 'DAILY CONVERSATION',
        sentence:
            'Everyone was impressed by how $word she remained throughout the challenging discussion.',
      ),
    ];

    final collocations = [
      'deeply $word',
      '$word effort',
      'remain $word',
      'cultivate $word',
      'highly $word',
    ];

    final nuances = [
      NuanceItem(
        synonym: 'persistent',
        difference: '$capitalized implies enduring through difficulty with strength.',
      ),
      NuanceItem(
        synonym: 'tenacious',
        difference: 'Tenacious emphasizes holding on fiercely without letting go.',
      ),
    ];

    return ContextWizardResult(
      word: word,
      sentences: sentences,
      collocations: collocations,
      nuances: nuances,
    );
  }

  static final Map<String, ContextWizardResult> _specializedCorpus = {
    'resilient': const ContextWizardResult(
      word: 'resilient',
      sentences: [
        ContextSentence(
          domain: 'WORK / ENGINEERING',
          sentence:
              'We refactored the message queue to build a resilient distributed microservice.',
        ),
        ContextSentence(
          domain: 'READING / ESSAY',
          sentence:
              'Children who grow up overcoming adversity often become remarkably resilient adults.',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Despite the sudden flight cancellation, he stayed positive and resilient.',
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
          difference: 'Tough means strong, but resilient means bouncing back after damage.',
        ),
        NuanceItem(
          synonym: 'durable',
          difference: 'Durable applies mostly to physical objects; resilient applies to minds, code, and systems.',
        ),
      ],
    ),
    'tenacious': const ContextWizardResult(
      word: 'tenacious',
      sentences: [
        ContextSentence(
          domain: 'WORK / CODING',
          sentence:
              'She showed tenacious debugging skills tracking down the race condition in the kernel.',
        ),
        ContextSentence(
          domain: 'PODCAST / NEWS',
          sentence:
              'The investigative journalist was tenacious in uncovering the financial irregularities.',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'His tenacious grip on the lead carried him across the marathon finish line.',
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
          difference: 'Stubborn has a negative connotation (unreasonable); tenacious is positive (determined).',
        ),
        NuanceItem(
          synonym: 'persistent',
          difference: 'Persistent simply keeps going; tenacious refuses to give up despite severe setbacks.',
        ),
      ],
    ),
    'eloquent': const ContextWizardResult(
      word: 'eloquent',
      sentences: [
        ContextSentence(
          domain: 'WORK / PRESENTATION',
          sentence:
              'She gave an eloquent keynote explaining the new product vision to our stakeholders.',
        ),
        ContextSentence(
          domain: 'READING / LITERATURE',
          sentence:
              'The essay provided an eloquent defense of open-source software collaboration.',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'He was so eloquent in his apology that everyone immediately forgave him.',
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
          difference: 'Fluent means speaking smoothly without pauses; eloquent means persuasive and moving.',
        ),
        NuanceItem(
          synonym: 'articulate',
          difference: 'Articulate means expressing ideas clearly; eloquent has emotional and aesthetic resonance.',
        ),
      ],
    ),
    'serendipity': const ContextWizardResult(
      word: 'serendipity',
      sentences: [
        ContextSentence(
          domain: 'WORK / DISCOVERY',
          sentence:
              'Finding that open-source library was pure serendipity that saved us two weeks of development.',
        ),
        ContextSentence(
          domain: 'READING / BIOGRAPHY',
          sentence:
              'Penicillin was discovered through a famous stroke of scientific serendipity.',
        ),
        ContextSentence(
          domain: 'DAILY CONVERSATION',
          sentence:
              'Meeting my college roommate at Tokyo airport was absolute serendipity.',
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
          difference: 'Luck is purely random; serendipity specifically means finding something valuable when looking for something else.',
        ),
        NuanceItem(
          synonym: 'coincidence',
          difference: 'A coincidence can be good or bad; serendipity is always a fortunate, happy discovery.',
        ),
      ],
    ),
  };
}
