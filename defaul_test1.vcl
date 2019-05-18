vcl 4.0;

# Imports
import std;
import directors;


acl purge {
  "199.73.109.198"/24;
  "192.168.1.0"/24;
  "127.0.0.1"/24;
}

# Default backend definition. Set this to point to your content server.
backend default {
    .host = "127.0.0.1"; # UPDATE this only if the web server is not on the same machine
    .port = "8080";      # UPDATE 8080 with your web server's (internal) port
}

# Define the director that determines how to distribute incoming requests.
sub vcl_init {
  new bar = directors.fallback();
  bar.add_backend(default);
}

sub vcl_recv {

    if (req.restarts == 0) {
	if (req.http.x-forwarded-for) {
	    set req.http.X-Forwarded-For =
		req.http.X-Forwarded-For + ", " + client.ip;
	} else {
	    set req.http.X-Forwarded-For = client.ip;
	}
    }
	set req.backend_hint = bar.backend();

  # Allow purging
  if (req.method == "PURGE") {
    if (!client.ip ~ purge) { # purge is the ACL defined at the begining
      # Not from an allowed IP? Then die with an error.
      return (synth(405, "This IP is not allowed to send PURGE requests."));
    }
    # If you got this stage (and didn't error out above), purge the cached result
    return (purge);
  }

  # Do not cache these paths.
  if (req.url ~ "^/status\.php$" ||
      req.url ~ "^/update\.php" ||
      req.url ~ "^/install\.php" ||
      req.url ~ "^/apc\.php$" ||
      req.url ~ "^/admin" ||
      req.url ~ "^/admin/.*$" ||
      req.url ~ "^/user" ||
      req.url ~ "^/user/.*$" ||
      req.url ~ "^/users/.*$" ||
      req.url ~ "^/info/.*$" ||
      req.url ~ "^/flag/.*$" ||
      req.url ~ "^.*/ajax/.*$" ||
      req.url ~ "^.*/ahah/.*$" ||
      req.url ~ "^/system/files/.*$" ||
      req.url ~ "^/js/admin_menu/cache/.*$") {

    return (pass);
  }

  if (req.url ~ "(?i)\.(pdf|asc|dat|txt|doc|xls|ppt|tgz|csv|png|gif|jpeg|jpg|ico|swf|css|js)(\?.*)?$") {
    unset req.http.Cookie;
  }

  if (req.http.Cookie) {
    set req.http.Cookie = ";" + req.http.Cookie;
    set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
    set req.http.Cookie = regsuball(req.http.Cookie, ";(SESS[a-z0-9]+|SSESS[a-z0-9]+|NO_CACHE)=", "; \1=");
    set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");

    if (req.http.Cookie == "") {
      unset req.http.Cookie;
    }
    else {
      return (pass);
    }
  }
#ended innoppl-team
}

sub vcl_backend_response {

    # Don't cache 50x responses
    if (
        beresp.status == 500 ||
        beresp.status == 502 ||
        beresp.status == 503 ||
        beresp.status == 504
    ) {
        return (abandon);
    }

  # Do not cache these paths.
  if (bereq.url ~ "^/status\.php$" ||
      bereq.url ~ "^/update\.php" ||
      bereq.url ~ "^/install\.php" ||
      bereq.url ~ "^/apc\.php$" ||
      bereq.url ~ "^/admin" ||
      bereq.url ~ "^/admin/.*$" ||
      bereq.url ~ "^/user" ||
      bereq.url ~ "^/user/.*$" ||
      bereq.url ~ "^/users/.*$" ||
      bereq.url ~ "^/info/.*$" ||
      bereq.url ~ "^/flag/.*$" ||
      bereq.url ~ "^.*/ajax/.*$" ||
      bereq.url ~ "^.*/ahah/.*$" ||
      bereq.url ~ "^/system/files/.*$" ||
      bereq.url ~ "^/js/admin_menu/cache/.*$") {

    return (deliver);
  }

    # Don't cache HTTP authorization/authentication pages and pages with certain headers or cookies
    if (
        bereq.http.Authorization ||
        bereq.http.Authenticate ||
        bereq.http.X-Logged-In == "True" ||
        bereq.http.Cookie ~ "userID")
     {
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Don't cache backend response to posted requests
    if (bereq.method == "POST") {
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Check for the custom "X-Logged-In" header to identify if the visitor is a guest,
    # then unset any cookie (including session cookies) provided it's not a POST request.
    if(beresp.http.X-Logged-In == "False" && bereq.method != "POST") {
        unset beresp.http.Set-Cookie;
    }

    # Unset the "etag" header (suggested)
    unset beresp.http.etag;

    # Unset the "pragma" header
    unset beresp.http.Pragma;

    # Allow stale content, in case the backend goes down
    set beresp.grace = 12h;

    # This is how long Varnish will keep cached content
    set beresp.ttl = 180s;

    if (bereq.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|ogg|ogm|opus|otf|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {
        unset beresp.http.set-cookie;
        set beresp.do_stream = true;
    }

    if (beresp.http.Cache-Control !~ "max-age" || beresp.http.Cache-Control ~ "max-age=0" || beresp.ttl < 180s) {
        set beresp.http.Cache-Control = "public, max-age=180, stale-while-revalidate=360, stale-if-error=43200";
    }

    return (deliver);

}

sub vcl_deliver {

    # Send special headers that indicate the cache status of each web page
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }

    return (deliver);

}

sub vcl_synth {
  if(resp.status == 850) {
    set resp.http.Location = "https://" + req.http.host + req.url;
    set resp.status = 301;
     return(deliver);
    }
}


sub vcl_hash {
  hash_data(req.http.X-Forwarded-Proto);
}
