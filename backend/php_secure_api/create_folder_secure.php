<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

$root = (string) ($_POST['root'] ?? '');
$parent = (string) ($_POST['parent'] ?? '');
$folder = sanitize_segment((string) ($_POST['folder'] ?? ''));

if ($folder === '') {
    json_response(['success' => false, 'message' => 'Folder is required.'], 400);
}

$resolved = resolve_target_path($root, $parent . '/' . $folder);
ensure_parent_dir($resolved['full']);

json_response(['success' => true]);
