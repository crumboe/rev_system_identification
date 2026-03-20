# Tutorial System Implementation Plan

## Phase 1: Data Model & Riverpod Integration

- [ ] Create `lib/ui/tutorials/tutorial_models.dart`
  - [ ] Define `TutorialTopic` class (id, title, category, steps, requiredScreen)
  - [ ] Define `TutorialStep` class (title, description, animationAsset, highlights, customContent, narration)
  - [ ] Define `HighlightRegion` class (widgetKey, highlightColor, label)

- [ ] Update `lib/state/app_state.dart` with Riverpod providers
  - [ ] `tutorialCompletionProvider` - StateNotifierProvider tracking completed tutorial IDs
  - [ ] `activeTutorialProvider` - StateProvider for currently active tutorial
  - [ ] `tutorialVisitedProvider` - Provider to track first-time visits to screens

## Phase 2: Tutorial Content Definition

- [ ] Create `lib/ui/tutorials/tutorial_data.dart` with topic definitions
  
  ### Hardware Topics
  - [ ] Motor & Encoder Assembly (3-4 steps)
  - [ ] SPARK Controller Wiring (3-4 steps with CAN/PWM/power highlights)
  - [ ] Breadboard & Power Distribution (2-3 steps)
  - [ ] USB Connection (1-2 steps)
  - [ ] E-stop & Mechanism Limits (2 steps)
  
  ### Software Topics
  - [ ] Device Connection Flow (2-3 steps)
  - [ ] Mechanism Type Selection (2 steps with enum explanation)
  - [ ] Encoder Configuration (3 steps - primary/absolute, zeroing)
  - [ ] Soft Limits Setup (2 steps, arm-specific)
  - [ ] Motor ID & Direction (2 steps)
  
  ### Electrical Topics
  - [ ] Power & Ground Distribution (2-3 steps with circuit diagram)
  - [ ] CAN Networking (2-3 steps with daisy-chain diagram)
  - [ ] Signal Path (2 steps)
  
  ### Testing Workflow Topics
  - [ ] Quasistatic Test Explained (2-3 steps with animated ramp)
  - [ ] Dynamic Test Explained (2 steps with step response)
  - [ ] Running Your First Test (3 steps)
  - [ ] Understanding Test Data (2 steps)
  
  ### Constants Deep Dive Topics
  - [ ] kS Explained (2 steps with static friction diagram)
  - [ ] kV Explained (2 steps with velocity graph)
  - [ ] kA Explained (2 steps with acceleration term)
  - [ ] kG Explained (2-3 steps, angle-dependent for arm)
  - [ ] PID Gains Explained (3 steps with pole-zero map)
  
  ### Best Practices Topics
  - [ ] Common Mistakes (3 steps)
  - [ ] Validation Check (2 steps)
  - [ ] Exporting & Using Results (2 steps)

## Phase 3: UI Components

- [ ] Create `lib/ui/tutorials/components/highlight_overlay.dart`
  - [ ] `HighlightOverlay` widget - renders semi-transparent overlay with highlighted regions
  - [ ] Animated pulse/glow effect on highlighted UI elements
  - [ ] Support for arrow/label pointing to regions

- [ ] Create `lib/ui/tutorials/components/step_navigator.dart`
  - [ ] Next/Previous buttons with enabled/disabled states
  - [ ] Step counter display ("Step X of Y")
  - [ ] Skip/Mark Complete buttons
  - [ ] Keyboard support (arrow keys, Escape)

- [ ] Create `lib/ui/tutorials/components/animation_viewer.dart`
  - [ ] Display Lottie animations from assets
  - [ ] Display SVG diagrams
  - [ ] Fallback placeholders if assets missing

## Phase 4: Main Tutorial Modal

- [ ] Create `lib/ui/tutorials/tutorial_modal.dart`
  - [ ] `TutorialModal` - main widget displaying full tutorial
    - [ ] Render current step content
    - [ ] Show animation/custom content area
    - [ ] Highlight relevant UI elements on current screen
    - [ ] Display step title, description, narration
    - [ ] Show breadcrumb/topic navigation
  - [ ] Handle step progression (next/prev)
  - [ ] Track completion in Riverpod
  - [ ] Support keyboard navigation

## Phase 5: Help Entry Points

- [ ] Add Help button to app shell / main screens
  - [ ] Update `lib/ui/app_shell.dart` with Help button in CommandBar
  - [ ] Add `onPressed` → show context-appropriate tutorial modal

- [ ] Add context-sensitive tutorial triggers
  - [ ] Auto-suggest tutorial on first visit to "Device" screen (if not connected)
  - [ ] Auto-suggest "Config" tutorial on first config visit
  - [ ] Auto-suggest "Test" tutorial on first test visit

- [ ] Add "Learn more" links in existing tooltips/help text
  - [ ] Link tooltips in config screen to related tutorial topics
  - [ ] Link chart annotations to concept tutorials

## Phase 6: Tutorial Browser (Optional First Iteration)

- [ ] Create `lib/ui/tutorials/tutorial_browser.dart` (can defer to Phase 2)
  - [ ] Display all tutorials grouped by category
  - [ ] Show completion badges
  - [ ] Allow search/filter by topic

## Phase 7: Diagrams & Assets

- [ ] Create custom diagram widgets in `lib/ui/tutorials/diagrams/`
  - [ ] `MotorEncoderDiagram` - animated motor + encoder assembly
  - [ ] `CanWiringDiagram` - SPARK CAN chain with color-coded traces
  - [ ] `PowerDistributionDiagram` - PDB + SPARK + motor circuit
  - [ ] `ConstantPlotAnimator` - animated graphs for kS/kV/kA/kG
  - [ ] `PidPoleZeroMap` - pole-zero plot animator

- [ ] Create placeholder Lottie animations (or external tool exports)
  - [ ] `assets/animations/motor_spinning.json`
  - [ ] `assets/animations/encoder_position_change.json`
  - [ ] `assets/animations/voltage_ramp.json`
  - [ ] `assets/animations/step_response.json`

## Phase 8: Testing & Polish

- [ ] Unit tests
  - [ ] Test tutorial data schema (all steps valid)
  - [ ] Test Riverpod completion tracking
  - [ ] Test highlight region resolution

- [ ] Widget tests
  - [ ] Test modal navigation (next/prev)
  - [ ] Test keyboard shortcuts
  - [ ] Test modal appears on help button press
  - [ ] Test context-sensitive filtering

- [ ] Manual testing
  - [ ] Step through all tutorials on each target screen
  - [ ] Verify animations play smoothly
  - [ ] Verify highlights align with UI elements
  - [ ] Test completion persistence across sessions

## Phase 9: Accessibility & Localization

- [ ] Text-to-speech support
  - [ ] Wire narration field to TTS engine (optional toggle)
  - [ ] Provide written descriptions for all steps

- [ ] Keyboard-only navigation
  - [ ] Tab/Shift+Tab to navigate steps
  - [ ] Screen reader compatibility

- [ ] Localization setup (i18n)
  - [ ] Mark all tutorial strings for translation
  - [ ] Add to intl_messages.arb

## Phase 10: Documentation & Handoff

- [ ] Write tutorial content editing guide
  - [ ] How to add new topic/step
  - [ ] How to update diagrams
  - [ ] How to add Lottie animations

- [ ] Add inline code documentation
  - [ ] Docstring examples
  - [ ] Diagram customization patterns

- [ ] Create tutorial creation checklist
  - [ ] Template for new topics
  - [ ] Asset naming conventions

---

## Notes

- Start with Phase 1-2 to establish data structure
- Phase 3-4 creates core UI
- Phase 5 integrates with app (adds entry points)
- Phase 6-7 enhance polish (deferred if needed)
- Phase 8-10 are quality/accessibility focused