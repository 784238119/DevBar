# Design QA

- Source visual truth: `/Users/calo/.codex/generated_images/019ff3c6-b71e-7410-8711-beed760c790c/exec-03425602-ed16-47e0-b50b-62700a947b83.png`
- Implementation screenshot: `/private/tmp/devbar-service-list-final.jpeg`
- Viewport: native macOS settings window, 980 x 680 pt capture
- Source pixels: 1774 x 887; implementation pixels: 980 x 680
- Normalization: the source is a conceptual crop of the service section while the implementation is the complete settings window. Comparison used the visible service-list region and matched the light appearance, three-service data set, and expanded `服务端` state. No density resampling was used.
- State: `客户端` and `运营端` collapsed; `服务端` expanded; HTTP health check; all services included in start-all.

## Full-view comparison evidence

The implementation preserves the source hierarchy inside the real 980 x 680 DevBar settings window: one grouped service surface, lightweight row separators, aligned identity/health/action columns, a compact disclosure command panel, and a footer interaction hint. The surrounding workspace settings remain unchanged.

## Focused region comparison evidence

- Identity: status, service icon, disclosure, service name, and directory are aligned consistently across all three rows.
- Health: every row uses the same waveform icon; HTTP displays only the protocol badge and never exposes the configured address.
- Actions: the native switch, ellipsis menu, and drag handle form one stable right-side group without the old protruding drag capsule.
- Expanded detail: the command uses a terminal SF Symbol, small label, monospaced value, subtle tint, and one-line middle truncation.
- Copy: the footer accurately describes the implemented edit and reorder affordances.

## Findings

No actionable P0, P1, or P2 differences remain.

- P3: macOS may render an enabled native switch with a subdued track when the captured window is not key. The implementation explicitly applies the workspace tint and retains the native switch for correct focus, keyboard, and accessibility behavior.

## Interaction evidence

- Disclosure expand/collapse was exercised in the real Debug app; the accessibility label changes from `展开 服务端` to `收起 服务端` and the command detail appears only while expanded.
- The overflow menu was opened in the real Debug app and exposes `编辑服务` and destructive `删除服务` actions.
- The switch remains an independent native control; a deliberately invalid isolated fixture rolled persistence back as expected without collapsing the expanded row.
- Dragging collapses open command details before measuring the fixed row stride, preventing variable-height reorder jumps.
- Existing reorder behavior tests passed in both directions:
  - `testDraggingServiceDownPlacesItAfterTarget`
  - `testDraggingServiceUpPlacesItBeforeTarget`

## Comparison history

1. Initial implementation: grouped rows, disclosure, protocol-only health detail, menu, and integrated drag handle were present. P2 differences were a missing footer affordance hint and non-explicit switch tint.
2. Final implementation: added the interaction hint and explicit workspace tint, rebuilt, reopened the isolated Debug app, expanded `服务端`, and captured `/private/tmp/devbar-service-list-final.jpeg`. No P0/P1/P2 findings remain.

## Verification

- Debug app build: passed.
- Targeted service reorder tests: 2 passed, 0 failed.
- Native window inspection: completed with the isolated UI-test configuration.
- Focused full-view comparison: completed with source and implementation supplied together.

final result: passed
