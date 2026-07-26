## MODIFIED Requirements

### Requirement: Menu bar is unavailable during focus mode

During focus mode, the macOS menu bar SHALL be entirely unavailable and SHALL NOT remain visible as live, blurred, or frozen imagery.
The system SHALL restore the application presentation behavior that was active before focus mode when focus is deactivated.

#### Scenario: Focus activated with a normally visible menu bar

- **WHEN** focus mode is activated while the menu bar is normally visible
- **THEN** the Apple logo, application menus, status items, clock, and menu bar background disappear completely

#### Scenario: Pointer reaches the top edge during focus

- **WHEN** focus mode is active and the pointer moves to the top edge of a display
- **THEN** the menu bar remains unavailable

#### Scenario: Another application is foreground

- **WHEN** focus mode is active and another application becomes or remains the foreground application
- **THEN** that application's menu bar remains completely covered on every enabled display
- **AND** the foreground application continues receiving keyboard and pointer input

#### Scenario: Deep mode is presented

- **WHEN** focus mode is active in Deep mode
- **THEN** the displayed result contains no Apple logo, menu titles, status items, clock, menu bar background, or blurred or frozen representation of them
- **AND** the effect remains visually continuous across the full display

#### Scenario: Focus deactivated

- **WHEN** focus mode is deactivated
- **THEN** the application presentation behavior returns to the state that was active before focus mode

#### Scenario: Hyperfocus terminates while focus is active

- **WHEN** Hyperfocus terminates normally while focus mode is active
- **THEN** the application restores the presentation behavior that was active before focus mode before terminating
