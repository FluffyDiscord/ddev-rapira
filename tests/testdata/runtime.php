<?php
header('Content-Type: text/plain');

echo 'sapi=', PHP_SAPI, "\n";

foreach (['memory_limit', 'max_execution_time', 'upload_max_filesize', 'post_max_size', 'variables_order', 'sendmail_path'] as $directive) {
    echo 'ini:', $directive, '=', ini_get($directive), "\n";
}

foreach (['pdo_pgsql', 'pgsql', 'intl', 'bcmath', 'gd', 'zip', 'redis', 'igbinary', 'sodium', 'Zend OPcache', 'xdebug', 'xhprof'] as $extension) {
    echo 'ext:', $extension, '=', extension_loaded($extension) ? 'yes' : 'no', "\n";
}

echo 'env:IS_DDEV_PROJECT=', $_ENV['IS_DDEV_PROJECT'] ?? '(missing)', "\n";
echo 'server:HTTP_X_FORWARDED_PROTO=', $_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '(missing)', "\n";
