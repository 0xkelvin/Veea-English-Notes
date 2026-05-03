// All UI strings in English and Vietnamese.
// Usage:
//   final s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
class AppStrings {
  final bool vi;
  const AppStrings(this.vi);

  // ── Common ────────────────────────────────────────────────────────────────
  String get dueToday => vi ? 'Cần ôn hôm nay' : 'Due Today';
  String get totalWords => vi ? 'Tổng số từ' : 'Total Words';
  String get words => vi ? 'từ' : 'words';
  String get backToStudy => vi ? 'Về trang học' : 'Back to Study';
  String get days => vi ? 'ngày' : 'days';
  String get startToday => vi ? 'Bắt đầu hôm nay!' : 'Start today!';

  // ── Rating ────────────────────────────────────────────────────────────────
  String get blackout => vi ? 'Không biết' : 'Blackout';
  String get blackoutDesc =>
      vi ? 'Hoàn toàn trống — không nhớ gì cả' : 'Complete blank — no memory at all';
  String get hard => vi ? 'Khó' : 'Hard';
  String get hardDesc => vi ? 'Rất khó, gần như đã quên' : 'Very difficult, almost forgot';
  String get good => vi ? 'Tốt' : 'Good';
  String get goodDesc => vi ? 'Nhớ được nhưng cần cố gắng' : 'Recalled with some effort';
  String get easy => vi ? 'Dễ' : 'Easy';
  String get easyDesc =>
      vi ? 'Nhớ hoàn toàn, không do dự' : 'Recalled perfectly without hesitation';
  String get howWellRemember =>
      vi ? 'Bạn nhớ đến đâu?' : 'How well did you remember?';
  String get ratingSubtitle =>
      vi
          ? 'Đánh giá của bạn quyết định khi nào từ này xuất hiện lại'
          : 'Your rating determines when this word appears next';

  // ── Home ──────────────────────────────────────────────────────────────────
  String get helloLearner => vi ? 'Xin chào!' : 'Hello, Learner';
  String get keepUpWork => vi ? 'Tiếp tục cố gắng nhé!' : 'Keep up the good work!';
  String get streak => vi ? 'Chuỗi ngày' : 'Streak';
  String get todaysWords => vi ? 'Từ hôm nay' : "Today's Words";
  String get settings => vi ? 'Cài đặt' : 'Settings';
  String get language => vi ? 'Ngôn ngữ' : 'Language';
  String get languageEnglish => vi ? 'Tiếng Anh' : 'English';
  String get languageVietnamese => vi ? 'Tiếng Việt' : 'Vietnamese';

  // ── Study Mode ────────────────────────────────────────────────────────────
  String get vocabStudy => vi ? 'Học từ vựng' : 'Vocabulary Study';
  String get chooseModeTitle => vi ? 'Chọn chế độ học' : 'Choose study mode';
  String get flashcard => 'Flashcard';
  String get flashcardSubtitle =>
      vi ? 'Lật thẻ, tự đánh giá mức độ nhớ (Anki)' : 'Flip cards and self-rate your recall (Anki)';
  String get multipleChoice => vi ? 'Trắc nghiệm' : 'Multiple Choice';
  String get multipleChoiceSubtitle =>
      vi ? 'Chọn đáp án đúng từ 4 lựa chọn (Quizlet)' : 'Pick the correct answer from 4 options (Quizlet)';
  String get needMoreWords =>
      vi ? 'Cần ít nhất 4 từ để chơi trắc nghiệm.' : 'Need at least 4 words to play multiple choice.';
  String get dueTodayFilter => vi ? 'Ôn tập hôm nay' : 'Due Today';
  String get allWords => vi ? 'Tất cả từ' : 'All Words';

  // ── Flashcard Screen ──────────────────────────────────────────────────────
  String get tapToFlip => vi ? 'Chạm để lật thẻ' : 'Tap to flip';
  String reviewStats(int count, int days) =>
      vi ? 'Lần ôn: $count  •  Khoảng cách: ${days}d' : 'Reviews: $count  •  Interval: ${days}d';
  String get showAnswer => vi ? 'Hiện đáp án' : 'Show Answer';
  String get done => vi ? 'Hoàn thành!' : 'Done!';
  String reviewedWords(int n) =>
      vi ? 'Bạn đã ôn $n từ.' : 'You reviewed $n words.';

  // ── Quiz Screen ───────────────────────────────────────────────────────────
  String get quizQuestion =>
      vi ? 'Nghĩa tiếng Việt của từ sau là gì?' : 'What is the Vietnamese meaning of this word?';
  String get correct => vi ? 'Đúng' : 'Correct';
  String get wrong => vi ? 'Sai' : 'Wrong';
  String get seeResults => vi ? 'Xem kết quả' : 'See Results';
  String get nextQuestion => vi ? 'Câu tiếp theo' : 'Next Question';
  String quizScore(int score, int total) =>
      vi ? '$score / $total câu đúng' : '$score / $total correct';
  String get tryAgain => vi ? 'Làm lại' : 'Try Again';
  String get excellentResult => vi ? 'Xuất sắc! 🎉' : 'Excellent! 🎉';
  String get needMorePractice => vi ? 'Cần luyện thêm 💪' : 'Keep practicing 💪';

  // ── Word Study Screen ─────────────────────────────────────────────────────
  String stepTitle(int step) => vi ? 'Bước $step/3' : 'Step $step/3';
  List<String> get stepTitles =>
      vi ? ['Flashcard', 'Gõ từ', 'Phát âm'] : ['Flashcard', 'Type It', 'Pronunciation'];
  String get tapToReveal => vi ? 'Nhấn để xem' : 'Tap to reveal';
  String get tapToRevealMeaning => vi ? 'Nhấn để xem nghĩa' : 'Tap to reveal meaning';
  String get typeEnglishWord => vi ? 'Gõ từ tiếng Anh tương ứng' : 'Type the English word';
  String get typeHint => vi ? 'Gõ từ tiếng Anh...' : 'Type the English word...';
  String get check => vi ? 'Kiểm tra' : 'Check';
  String get correctAnswer => vi ? 'Chính xác!' : 'Correct!';
  String answerIs(String word) => vi ? 'Đáp án đúng: $word' : 'Answer: $word';
  String get pronunciation => vi ? 'PHÁT ÂM TỪ NÀY' : 'PRONUNCIATION';
  String get tapToListen => vi ? 'Nhấn để nghe phát âm' : 'Tap to listen';
  String get gotIt => vi ? 'Đã thuộc' : 'Got it';
  String get continueStudy => vi ? 'Học tiếp' : 'Continue';
  String get finish => vi ? 'Hoàn thành' : 'Done';
}
