<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

if (!isset($_FILES['file']) || !is_array($_FILES['file'])) {
    json_response(['success' => false, 'message' => 'Missing file.'], 400);
}

$tmp = (string) ($_FILES['file']['tmp_name'] ?? '');
if ($tmp === '' || !is_uploaded_file($tmp)) {
    json_response(['success' => false, 'message' => 'Invalid upload temp file.'], 400);
}

$size = (int) ($_FILES['file']['size'] ?? 0);
if ($size <= 0 || $size > MAX_UPLOAD_BYTES) {
    json_response(['success' => false, 'message' => 'Invalid file size.'], 400);
}

$origName = (string) ($_FILES['file']['name'] ?? 'cv.pdf');
$safeName = sanitize_segment(pathinfo($origName, PATHINFO_FILENAME));
$ext = strtolower((string) pathinfo($origName, PATHINFO_EXTENSION));

if ($safeName === '') {
    $safeName = 'cv';
}
if ($ext !== 'pdf') {
    json_response(['success' => false, 'message' => 'Only PDF is allowed.'], 400);
}

$todayPath = date('Y/m');
$resolved = resolve_target_path('courses', 'job_cvs/' . $todayPath);
ensure_parent_dir($resolved['full']);

$finalName = $safeName . '_' . bin2hex(random_bytes(6)) . '.pdf';
$targetPath = $resolved['full'] . '/' . $finalName;

if (!move_uploaded_file($tmp, $targetPath)) {
    json_response(['success' => false, 'message' => 'Failed to save uploaded file.'], 500);
}

$rel = trim($resolved['clean'] . '/' . $finalName, '/');
$url = build_public_url($resolved['root'], $rel);

json_response([
    'success' => true,
    'url' => $url,
]);
