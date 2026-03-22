<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

$root = (string) ($_POST['root'] ?? '');
$path = (string) ($_POST['path'] ?? '');
$resolved = resolve_target_path($root, $path);

if (!is_file($resolved['full'])) {
    json_response(['success' => false, 'message' => 'File not found.'], 404);
}

if (!unlink($resolved['full'])) {
    json_response(['success' => false, 'message' => 'Delete failed.'], 500);
}

json_response(['success' => true]);
