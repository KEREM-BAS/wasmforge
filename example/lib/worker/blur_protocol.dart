/// Task names and payload keys shared between the app and the worker
/// entrypoint. Pure Dart — imported from both sides of the worker boundary.
library;

/// SAB mode: horizontal box-blur pass over a row band, reading/writing
/// shared memory in place.
const String blurHorizontalTask = 'blurH';

/// SAB mode: vertical box-blur pass over a row band.
const String blurVerticalTask = 'blurV';

/// Copy mode: both passes over a transferred band+halo slab; returns the
/// blurred band.
const String blurBandCopyTask = 'blurBandCopy';

/// Payload key: source [Object] — `SharedBuffer` in SAB mode.
const String keySrc = 'src';

/// Payload key: destination `SharedBuffer` (SAB mode).
const String keyDst = 'dst';

/// Payload key: image width in pixels.
const String keyWidth = 'width';

/// Payload key: image height in pixels (or slab height in copy mode).
const String keyHeight = 'height';

/// Payload key: first row of the band (inclusive).
const String keyStartRow = 'startRow';

/// Payload key: last row of the band (exclusive).
const String keyEndRow = 'endRow';

/// Payload key: blur radius in pixels.
const String keyRadius = 'radius';

/// Payload key: optional progress `SharedBuffer` (slot 0 is atomically
/// incremented once per completed band pass).
const String keyProgress = 'progress';

/// Payload key (copy mode): the transferred band+halo RGBA slab.
const String keySlab = 'slab';

/// Payload key (copy mode): number of rows in the slab.
const String keySlabRows = 'slabRows';

/// Payload key (copy mode): index of the band's first row inside the slab.
const String keyBandStartInSlab = 'bandStartInSlab';

/// Payload key (copy mode): number of rows in the band to return.
const String keyBandRows = 'bandRows';
