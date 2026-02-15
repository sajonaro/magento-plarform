<?php
header('Content-Type: application/json');
echo json_encode([
    'status' => 'healthy',
    'timestamp' => date('Y-m-d H:i:s'),
    'hostname' => gethostname(),
    'php_version' => phpversion()
]);