/// Page entry within a chapter, storing the page's index and its
/// character offset into the full book text.
class PageEntry {
  final int pageIndex;
  final int startOffset;

  const PageEntry({
    required this.pageIndex,
    required this.startOffset,
  });

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'startOffset': startOffset,
      };

  factory PageEntry.fromJson(Map<String, dynamic> json) => PageEntry(
        pageIndex: json['pageIndex'] as int,
        startOffset: json['startOffset'] as int,
      );
}

/// Pagination information for one chapter.
///
/// Stores two parallel page lists — one for fullscreen mode and one for
/// non-fullscreen mode — so switching between modes never requires
/// recomputation.
class ChapterPageInfo {
  final int chapterIndex;
  final String chapterTitle;

  /// Character offset where this chapter begins in the full book text.
  final int startOffset;

  /// Pages computed for fullscreen mode.
  final List<PageEntry> fullScreenPages;

  /// Pages computed for non-fullscreen mode.
  final List<PageEntry> notFullScreenPages;

  /// Whether the initial 5-page batch has been computed.
  bool get hasInitialBatch => fullScreenPages.isNotEmpty;

  const ChapterPageInfo({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.startOffset,
    required this.fullScreenPages,
    required this.notFullScreenPages,
  });

  ChapterPageInfo copyWith({
    List<PageEntry>? fullScreenPages,
    List<PageEntry>? notFullScreenPages,
  }) =>
      ChapterPageInfo(
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        startOffset: startOffset,
        fullScreenPages: fullScreenPages ?? this.fullScreenPages,
        notFullScreenPages: notFullScreenPages ?? this.notFullScreenPages,
      );
}
