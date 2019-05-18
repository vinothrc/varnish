# Define the internal network subnet.
# These are used below to allow internal access to certain files while not
# allowing access from the public internet.

import std;

acl internal {
  "172.145.172.0"/24;
  "192.168.1.0"/24;
  "192.168.4.0"/24;
}

# Define the list of backends (web servers).
# Port 80 Backend Servers

backend default {
#     .host = "dev.local.com";
	.host = "localhost";
        .port = "10081";
}


sub vcl_recv {
// is this necessary?
//    set req.backend = default;

    if (req.restarts == 0) {
	if (req.http.x-forwarded-for) {
	    set req.http.X-Forwarded-For =
		req.http.X-Forwarded-For + ", " + client.ip;
	} else {
	    set req.http.X-Forwarded-For = client.ip;
	}
    }

if (req.request == "PURGE") {
   if (!client.ip ~ internal) {
      error 405 "Method not allowed";
   }
   return (lookup);
}

if ( req.http.user-agent ~ "Buzzumo"
   || req.http.referer ~ "adns.com"
   || req.http.referer ~ "sfer.com"
   ) {
   error 403 ;
   }

if (req.request != "GET" &&
    req.request != "HEAD" &&
    req.request != "PUT" &&
    req.request != "POST" &&
    req.request != "TRACE" &&
    req.request != "OPTIONS" &&
    req.request != "DELETE") {
      // Non-RFC2616 or CONNECT which is weird.
      return (pipe);
  }
 
  if (req.request != "GET" && req.request != "HEAD") {
    // We only deal with GET and HEAD by default
    return (pass);
  }

  # Use anonymous, cached pages if all backends are down.
    if (!req.backend.healthy) {
       unset req.http.Cookie;
    }

  # Allow the backend to serve up stale content if it is responding slowly.
  set req.grace = 6h;


  # Do not cache these paths.
  if (req.url ~ "^/status\.php$" ||
      req.url ~ "^/update\.php$" ||
      req.url ~ "^/ooyala/ping$" ||
      req.url ~ "^/admin/build/features" ||
      req.url ~ "^/info/.*$" ||
      req.url ~ "^/flag/.*$" ||
      req.url ~ "^.*/ajax/.*$" ||
      req.url ~ "^.*/ahah/.*$") {
       return (pass);
  }

# Do not cache health check
  if (req.url ~ "^/\.testpage\.php$")
     { return (pass); }

  # Pipe these paths directly to Apache for streaming.
  if (req.url ~ "^/admin/content/backup_migrate/export") {
    return (pipe);
  }

 
  # Do not allow outside access to cron.php or install.php.
  if (req.url ~ "^/(cron|install)\.php$" && !client.ip ~ internal) {
    # Have Varnish throw the error directly.
    error 404 "Page not found.";
    # Use a custom error page that you've defined in Drupal at the path "404".
    # set req.url = "/404";
  }

 // Skip the Varnish cache for install, update, and cron
  if (req.url ~ "install\.php|update\.php|cron\.php") {
    return (pass);
  }


  # Handle compression correctly. Different browsers send different
  # "Accept-Encoding" headers, even though they mostly all support the same
  # compression mechanisms. By consolidating these compression headers into
  # a consistent format, we can reduce the size of the cache and get more hits.=
  # @see: http:// varnish.projects.linpro.no/wiki/FAQ/Compression
  if (req.http.Accept-Encoding) {
    if (req.http.Accept-Encoding ~ "gzip") {
      # If the browser supports it, we'll use gzip.
      set req.http.Accept-Encoding = "gzip";
    }
    else if (req.http.Accept-Encoding ~ "deflate") {
      # Next, try deflate if it is supported.
      set req.http.Accept-Encoding = "deflate";
    }
    else {
      # Unknown algorithm. Remove it and send unencoded.
      unset req.http.Accept-Encoding;
    }
  }

// Remove all cookies from static files
if (req.url ~ "\.(png|gif|jpg|swf|css|js|htm|ico|html)(\?.*|)$") {
      unset req.http.cookie;
      unset req.http.Accept-Encoding;
      unset req.http.Vary;
    }

// Remove has_js and Google Analytics cookies.

//  set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(__[a-z]+|__utma_a2a|has_js)=[^;]*", "");
// strip GA cookies or has_js cookies
set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(_[_a-zA-Z0-9]+|has_js|sd|click_source|sid|sb_code|Drupal.toolbar.collapsed|JSESSIONID)\s?=(\s?[^;]*)?", ""); 
// strip cookies that are only semi-colons and white space
set req.http.Cookie = regsuball(req.http.Cookie, "^[;\s]+$", "");

set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");
  // To users: if you have additional cookies being set by your system (e.g.
  // from a javascript analytics file or similar) you will need to add VCL
  // at this point to strip these cookies from the req object, otherwise
  // Varnish will not cache the response. This is safe for cookies that your
  // backend (Drupal) doesn't process.
  //
  // Again, the common example is an analytics or other Javascript add-on.
  // You should do this here, before the other cookie stuff, or by adding
  // to the regular-expression above.
 
 
  // Remove a ";" prefix, if present.
  set req.http.Cookie = regsub(req.http.Cookie, "^;\s*", "");
  // Remove empty cookies.
  if (req.http.Cookie ~ "^\s*$") {
    unset req.http.Cookie;
  }
 
  if (req.http.Authorization || req.http.Cookie) {
    // Not cacheable by default 
    return (pass);
  }

    return (lookup);
}

sub vcl_pipe {
    # Note that only the first request to the backend will have
    # X-Forwarded-For set.  If you use X-Forwarded-For and want to
    # have it set for all requests, make sure to have:
    # set bereq.http.connection = "close";
    # here.  It is not set by default as it might break some broken web
    # applications, like IIS with NTLM authentication.
    return (pipe);
}

sub vcl_pass {
if (req.request == "PURGE") {
   error 502 "PURGE on a passed object";
   }
    return (pass);
}

sub vcl_hash {
    hash_data(req.url);
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
    return (hash);
}

sub vcl_hit {
if (req.request == "PURGE") {
   purge;
   error 200 "Purged";
   }
   return (deliver);
}

sub vcl_miss {
if (req.request == "PURGE") {
   purge;
   error 404 "Not in cache";
   }
    return (fetch);
}

sub vcl_fetch {
    if (beresp.status == 301) {
       set beresp.ttl = 15m;
       set beresp.http.Cache-Control = "public, max-age=900";    
       unset beresp.http.set-cookie;
    }

    if (beresp.status == 404) {
       set beresp.ttl = 30s;
    }

    // Strip any cookies before an image/js/css is inserted into cache.
   if (req.url ~ "\.(png|gif|jpg|swf|css|js|htm|ico|html)(\?.*)?$") {
    // For Varnish 2.0 or earlier, replace beresp with obj:
    // unset obj.http.set-cookie;
      set beresp.ttl = 15m; 
      set beresp.http.Cache-Control = "public, max-age=604800";
      set beresp.http.Vary = "Accept-Encoding";
      unset beresp.http.set-cookie;
    }
if (req.url ~ "\.(htm|html|txt|css|js)$") {
                set beresp.do_gzip = true;
        }

   if (beresp.http.Cache-Control ~ "public") {
#       set beresp.ttl = 15m;
#       set beresp.http.Cache-Control = "public, max-age=900";
       unset beresp.http.set-cookie;
    } 


    if (beresp.ttl <= 0s ||
        beresp.http.Set-Cookie ||
        beresp.http.Vary == "*") {
                /*
                 * Mark as "Hit-For-Pass" for the next 2 minutes
                 */
                set beresp.ttl = 120 s;
                return (hit_for_pass);
    }
    

    

  # Allow items to be stale if needed.
  set beresp.grace = 6h;

    return (deliver);
}

sub vcl_deliver {
     if (obj.hits > 0) {
     	    set resp.http.X-Varnish-Cache = "HIT";
  	}
  	else {
            set resp.http.X-Varnish-Cache = "MISS";
    	}
    return (deliver);
}

/*
 * We can come here "invisibly" with the following errors:  413, 417 & 503
 */
/*
sub vcl_error {
    set obj.http.Content-Type = "text/html; charset=utf-8";
    set obj.http.Retry-After = "5";
    synthetic {"
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
 "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
  <head>
    <title>"} + obj.status + " " + obj.response + {"</title>
  </head>
  <body>
    <h1>Error "} + obj.status + " " + obj.response + {"</h1>
    <p>"} + obj.response + {"</p>
    <h3>Guru Meditation:</h3>
    <p>XID: "} + req.xid + {"</p>
    <hr>
    <p>Varnish cache server</p>
  </body>
</html>
"};
    return (deliver);
}*/

# In the event of an error, show friendlier messages.
sub vcl_error {
  # Redirect to some other URL in the case of a homepage failure.
  #if (req.url ~ "^/?$") {
  #  set obj.status = 302;
  #  set obj.http.Location = "http://backup.example.com/";
  #}

  # Otherwise redirect to the homepage, which will likely be in the cache.
  set obj.http.Content-Type = "text/html; charset=utf-8";
  synthetic {"
<html>
<head>
  <title>Page Unavailable</title>
  <style>
    body { background: #303030; text-align: center; color: white; }
    #page { border: 1px solid #CCC; width: 500px; margin: 100px auto 0; padding: 30px; \
background: #323232; }
    a, a:link, a:visited { color: #CCC; }
    .error { color: #222; }
  </style>
</head>
<body onload="setTimeout(function() { window.location = '/' }, 5000)">
  <div id="page">
    <h1 class="title">Page Unavailable</h1>
    <p>The page you requested is temporarily unavailable.</p>
    <p>We're redirecting you to the <a href="/">homepage</a> in 5 seconds.</p>
    <div class="error">(Error "} + obj.status + " " + obj.response + {")</div>
  </div>
</body>
</html>
"};
  return (deliver);
}


sub vcl_init {
	return (ok);
}

sub vcl_fini {
	return (ok);
}

