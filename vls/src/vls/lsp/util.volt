module vls.lsp.util;

import watt = [watt.text.string, watt.text.path, watt.io, watt.io.file, watt.path];

//! @Returns The directory where a URI file resides, or `null`.
fn getPathFromUri(uri: string) string
{
	if (uri.length < 8 || uri[0 .. 8] != "file:///") {
		return null;
	}
	version (Windows) {
		trimAmount := 8;
	} else {
		trimAmount := 7;
	}
	uri = uri[trimAmount .. $];
	uri = watt.replace(uri, "%3A", ":");
	return uri;
}

//! @Returns `path` as a URI.
fn getUriFromPath(path: string) string
{
	if (path is null) {
		return null;
	}
	uri := watt.normalisePath(path);
	version (Windows) {
		uri = watt.replace(uri, ":", "%3A");
		uri = watt.replace(uri, "\\", "/");
	}
	uri = new "file:///${uri}";
	return uri;
}

/*!
 * Get the `battery.toml` file associated with a file path.
 *
 * Given a path to a source file, `getBatteryToml` will go up
 * the file tree until it finds a `src` directory, at which point
 * it will look for a `battery.toml` file. If it finds it, it
 * will return the path to it. If that file doesn't exist, or a
 * `src` directory is never found, this function will return null.
 */
fn getBatteryToml(path: string) string
{
	basePath := watt.dirName(path);
	while (basePath !is null) {
		if (watt.endsWith(basePath, "/src") || watt.endsWith(basePath, "\\src")) {
			parentDirectory(ref basePath);
			btoml := watt.concatenatePath(basePath, "battery.toml");
			if (watt.exists(btoml)) {
				return btoml;
			} else {
				return null;
			}
		}
		parentDirectory(ref basePath);
	}
	return null;
}

private fn parentDirectory(ref path: string)
{
	while (path.length > 0 && path[$-1] != '/' && path[$-1] != '\\') {
		path = path[0 .. $-1];
	}
	if (path.length > 0) {
		path = path[0 .. $-1];  // Trailing slash.
	}
}
