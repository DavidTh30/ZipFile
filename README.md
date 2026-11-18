# ZipFile
ZipFile

Windows package. Unzip and double-click BGRAZip.exe; nothing to install. Includes rar_pure.exe (64-bit), the new engine for password-protected archives; keep it next to BGRAZip.exe.

Passwords for extracting and creating ZIP and RAR

Extracting or testing a password-protected archive asks for the password once (masked input; leave it empty to extract only the files without one).
New "Password" box and "hide names" option next to Compression: create ZIP (AES-256 or ZipCrypto) and RAR5 archives with a password, optionally with encrypted file names.
RAR archives with encrypted file names can now be tested and extracted.

rar_pure.exe engine

Extracts ZIP and RAR and creates ZIP and RAR5 when it is next to the program; without it the old paths (built-in zipper, WinRAR / 7-Zip / tar) are used as before.
Thai and other non-ASCII paths are handled (short names and an ASCII staging folder). Passwords must be ASCII.
Passwords are masked in the developer log.

MCP and IPC

"password" on extract_archive and test_archive; "password" and "zipcrypto" on create_zip; new create_rar ("password", "encrypt_names"); rar_tools reports rar_pure.
IPC extract and test accept "password".
