// worker/jobs/test/lib/jobs-schema.js — a helper for the node test corpus.
//
// It will compose worker/jobs/schema.sql from worker/jobs/schema.d/ for the
// node suites that read the file, once the file leaves git (BH-6005). The
// BH-6005 test-corpus child owns it and writes its body. It is empty in
// BH-6005.0 on purpose: this child only creates the seam so the siblings do
// not collide on creating it.
