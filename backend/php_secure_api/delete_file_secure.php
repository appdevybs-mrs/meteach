<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

$root = trim((string) ($_POST['root'] ?? $_GET['root'] ?? ''));
$path = trim((string) ($_POST['path'] ?? $_GET['path'] ?? ''));

if ($root === '' || $path === '') {
    json_response(['success' => false, 'message' => 'Missing root/path.'], 400);
}

$resolved = resolve_target_path($root, $path);

if (is_dir($resolved['full'])) {
    json_response(['success' => false, 'message' => 'Path is a directory. Use delete_item_secure.php.'], 400);
}

if (!is_file($resolved['full'])) {
    json_response(['success' => false, 'message' => 'File not found.'], 404);
}

if (!unlink($resolved['full'])) {
    json_response(['success' => false, 'message' => 'Delete failed.'], 500);
}

json_response(['success' => true, 'deleted' => $resolved['clean']]);
