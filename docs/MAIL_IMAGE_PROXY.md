# Remote mail image privacy and bounds

Images are blocked by default. Choosing to load remote images asks the authenticated Harbor server to fetch only sources currently present in that stored message. The request is bound to its account/message and ownership is rechecked before cached reads and after fetching. Browser errors never fall back to the original URL. Viewing a message does not itself consent to image loading.

The server contacts the image host on explicit opt-in; that host can observe the server's request and the image-specific URL. Proxying removes the browser's direct network contact, not every tracking signal encoded in a unique image URL.

The fetcher uses pinned public DNS results, rejects private/reserved/transition addresses, redirects and nonstandard HTTP(S) ports, and sends no user cookies, bearer credentials, ambient proxy credentials or client certificates. HTTPS still verifies the hostname. No target URL or response body is included in user-visible errors.

Only PNG, JPEG and GIF are decoded (first frame) using built-in JDK readers and re-encoded into a fresh PNG. Format signatures are checked before decoder selection. PNG chunk lengths, CRCs and dimensions are checked and non-rendering metadata is removed before decoding. BMP and SVG are rejected, including embedded-image BMP variants whose declared allocation could bypass ordinary pixel bounds. Unsupported data/CID resources remain placeholders.

Limits include 4 MiB input/output, 8 million pixels, 8192 pixels per dimension, 8 seconds total, 1.5 seconds DNS and 2 seconds per socket I/O operation. PNG encoding uses an explicitly bounded 4 MiB seekable memory cache, avoiding ImageIO's default temporary-file output cache. Fetch/DNS worker pools and admission queues are bounded. A message has at most 32 distinct image sources. The cache has 10-minute validity, bounded entries and lazy cleanup; this is not a promise of immediate physical erasure at ten minutes.

The client stops on authentication expiry, uses a 16 MiB aggregate result budget and permits at most 32 rendered image placements with a bounded aggregate data-URL budget. Duplicate sources count again toward the rendering budget, preventing a short hostile message from repeating one large image into an enormous iframe document.

All image tests use generated raster bytes and synthetic fixtures. Real-browser checks additionally require decoded natural image dimensions and zero direct-origin requests. They do not access real mailboxes or production image URLs.
