/// Store on disk: layout, content-addressed artifacts, downloads, GC,
/// journal, project registry (docs/05, docs/06 §6).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/artifact_store.dart';
export 'src/download_manager.dart';
export 'src/file_journal.dart';
export 'src/project_store_impl.dart';
export 'src/sdk_repository_impl.dart';
export 'src/store_layout.dart';
export 'src/store_lock.dart';
