# Q32b (118) paused branch notes

Paused by Aesop on token budget, 2026-10-24. No PR yet.

## Done (committed here)
- Classifier (lib/ostler-confirm-calendars.py): owner's possessive title is yours; another person's possessive or name is shared, not family; an address calendar is the owner's only if it is theirs (--owner-email) or carries their name or a work word; holiday feeds (URL) and Google holiday ids are holidays; one title from two holiday sources stays set aside; holidays sort together after ordinary calendars; 7th TSV column = picker category; empty middle fields written as "-" (bash read collapsed them).
- Picker mapping: answers_from_categories / write --rows --categories; a malformed answer keeps the pre-fill and logs why.
- install.sh: GUI path uses prompt calendar_assign (kind text, default = "category|count|name" lines, answer = CSV of categories, same timeout); terminal path unchanged apart from 7 columns and no "Family: Family, family".
- GUI: Views/CalendarAssignList.swift + OnboardingQuestionView wiring; ViewCopy keys under onboarding_question.calendar_assign; scroll content bottom padding (clipped toggle).
- Tests: tests/test_calendar_picker_guesses.py (12/12 red on main, 12/12 green), test_calendar_review_is_one_screen.sh 30/0 incl. GUI arms, walkaway allowlist for calendar_assign; 8 mutants all caught. pii guard CLEAN, maskless, wiring, pbxproj sync, py311, install-gui contract all green locally.

## Left
1. The Swift has NOT been compiled (heavy lock queue). Build the OstlerInstaller target first.
2. Screenshots before/after at the question-pane size (619x559): harness approach was an offscreen NSHostingView of OnboardingQuestionView compiled with swiftc -D DEBUG from gui/OstlerInstaller/*.swift minus App.swift. Never run the app or the XCTest host (TCC prompts).
3. Verify the clipped-toggle fix visually (padding is unproven).
4. HR015 ledger entry, PR, Archie review.
