// -*- mode: c++; tab-width: 8; c-basic-offset: 4; indent-tabs-mode: nil; -*-
#include "tame.h"
#include "tame_io.h"
#include "tame_connectors.h"
#include "tame_nlock.h"

struct selop_which_t {
  selop_which_t (int f, selop w) : _fd (f), _which (w) {}
  int _fd;
  selop _which;
};

template<> struct equals<selop_which_t> {
  equals () {}
  bool operator() (const selop_which_t &a, const selop_which_t &b) const
  { return (a._fd == b._fd && a._which == b._which); }
};

template<> struct hashfn<selop_which_t> {
  hashfn () {}
  bool operator() (const selop_which_t &x) const
  { return hash_t ((x._fd << 3) | int (x._which)); }
};

namespace tame {

void
clearread (int fd)
{
  fdcb (fd, selread, NULL);
}

void
clearwrite (int fd)
{
  fdcb (fd, selwrite, NULL);
}

tamed void
sigcb1 (int sig, evv_t cb)
{
  twait { sigcb (sig, connector::cnc (mkevent (), cb)); }
  sigcb (sig, NULL);
  cb->trigger ();
}


void
waitwrite (int fd, evv_t cb)
{
  fdcb1(fd, selwrite, cb);
}

void
waitread (int fd, evv_t cb)
{
  fdcb1(fd, selread, cb);
}

typedef enum { READ, WRITE, ENDPROG, POKE } ev_t;

void
iofd_sticky_t::on ()
{
  if (!_on && _ev)
    fdcb (_fd, _op, _ev);

  if (_ev) 
    _on = true;
}

void
iofd_sticky_t::off ()
{
  if (_on)
    fdcb (_fd, _op, NULL);

  _on = false;
}

void
iofd_sticky_t::finish ()
{
  off ();
  _ev = NULL;
}

tamed void
proxy (int infd, int outfd, evv_t ev)
{
  tvars {
    ref<std_proxy_t> px (New refcounted<std_proxy_t> ());
  }
  twait { px->go (infd, outfd, mkevent ()); }
  ev->trigger ();
}

bool
std_proxy_t::is_readable () const
{
  return (_sz > _buf.resid ());
}

bool
std_proxy_t::is_writable () const 
{
  return (_buf.resid () > 0);
}

int
std_proxy_t::v_read (int fd)
{
  return _buf.input (fd, _sz - _buf.resid ());
}

int 
std_proxy_t::v_write (int fd)
{
  return _buf.output (fd);
}

std_proxy_t::std_proxy_t (const str &d, ssize_t s) : 
  proxy_t (d), 
  _sz (s > 0 ? s : 0x4000) {}

std_proxy_t::~std_proxy_t () {}

void
proxy_t::do_debug (const str &msg) const
{
  if (msg && _debug_level > 0) {
    str s = _debug_name;
    if (!s) 
      s = "<anonymous>";
    warn << s << ": " << msg;
    if (msg[msg.len () - 1] != '\n')
      warnx << "\n";
  }
}

void
proxy_t::encountered_error ()
{
  set_eof ();
}

tamed void
proxy_t::go (int infd, int outfd, evv_t ev)
{
  tvars {
    rendezvous_t<ev_t> rv (__FILE__, __LINE__);
    ev_t which;
    int rc;
    bool err (false);
    iofd_sticky_t read (infd, selread), write (outfd, selwrite);
    bool cancelled (false);
    str s;
    holdvar ptr<proxy_t> hold (mkref (_self));
    str dn ("");
    bool async(false);
  }

  // if we're outputting an error message, it would be good to
  // know on which proxy we had a problem. in the case of 
  // OKWS's SSL proxy, we have 2 in parallel.
  if (_debug_name) { dn = strbuf (" (%s)", _debug_name.cstr ()); }

  // If the parent process gives up on us, then we'll get a callback here
  ev->set_cancel_notifier (mkevent (rv, ENDPROG));

  read.setev (mkevent (rv, READ));
  write.setev (mkevent (rv, WRITE));

  _poke_ev = mkevent (rv, POKE);
  _poke_ev->set_reuse (true);

  // MK 4/29/09:  Previously, we kept trying to write even
  // if the proxy was cancelled (to flush the buffer).  However,
  // that got us into trouble since we were still waiting for
  // file descriptors that were going to get closed. I think
  // the safe thing to do is just to abandon ship on cancellation.
  // We might revisit in the future and require that proxy takes
  // an rcfd_t; that's a surefire solution to the issue.
  while (!err && !cancelled && (!is_eof() || is_writable ())) {
    if (is_sync_readable() && !is_eof()) {
        which = READ;
        async = false;
    } else if (is_sync_writeable()) {
        which = WRITE;
        async = false;
    } else {
        async = true;
        if (is_readable () && !is_eof ()) read.on ();
        else read.off ();
    
        if (is_writable ()) write.on ();
        else write.off ();

        twait (rv, which);
    }

    switch (which) {
    case POKE:
      break;
    case READ: 
      if ((rc = v_read (read.fd())) == 0) {
          if (!async) {
              warn << "TV_ERROR: " __FILE__ "[" << __LINE__ << "]"
                   << " proxy lied about having async data available...\n";
          } else {
              do_debug ("EOF on socket");
              set_eof ();
          }
      } else if (rc < 0) {
	if (read_error (&s)) {
	  warn ("read error%s: %s\n", dn.cstr (), s.cstr ());
	  err = true;
	} else if (errno == ECONNRESET && 
		   allow_unclean_shutdowns ()) {
	  do_debug ("EOF on socket with ECONNRESET (in permissible mode)");
	  set_eof ();
	} else if (errno != EAGAIN) {
	  warn ("read error%s: %m\n", dn.cstr ());
	  err = true;
	}
      }
      do_debug (strbuf ("read() => (%d,%d)", rc, errno));
      break;
    case WRITE:
      if ((rc = v_write (write.fd())) < 0) {
	if (write_error (&s)) {
	  warn ("write error%s: %s\n", dn.cstr (), s.cstr ());
	  err = true;
	} else if (errno != EAGAIN) {
	  warn ("write error%s: %m\n", dn.cstr ());
	  err = true;
	}
      }
      do_debug (strbuf ("write() => (%d,%d)", rc, errno));
      break;
    case ENDPROG:
      do_debug ("end program");
      cancelled = true;
      break;
    default:
      panic ("unexpected case.\n");
    }
  }

  // Propogate this error to the other side, to potentially report
  // that there was an error.
  if (err) { encountered_error (); }

  do_debug ("leaving proxy loop");

  read.finish ();
  write.finish ();
  _poke_ev = NULL;

  ev->trigger ();
  rv.cancel (); // for the timer (if necessary )
}

bool
proxy_t::poke ()
{
  if (_poke_ev) {
    _poke_ev->trigger ();
    return true;
  } else {
    return false;
  }
}

tamed void
read (int fd, char *buf, size_t sz, evi_t ev)
{
  tvars { int rc; }

  twait { fdcb (fd, selread, mkevent ()); }
  fdcb (fd, selread, NULL);
  rc = ::read (fd, buf, sz);
  ev->trigger (rc);
}

tamed void
write (int fd, const char *buf, size_t sz, evi_t ev)
{
  tvars { int rc; }

  twait { fdcb (fd, selwrite, mkevent ()); }
  fdcb (fd, selwrite, NULL);
  rc = ::write (fd, buf, sz);
  ev->trigger (rc);
}

tamed void 
accept (int sockfd, struct sockaddr *addr, socklen_t *addrlen, evi_t ev)
{
  tvars { int rc; }
  
  twait { fdcb (sockfd, selread, mkevent ()); }
  fdcb (sockfd, selread, NULL);
  rc = ::accept (sockfd, addr, addrlen);
  ev->trigger (rc);
}
 
  //-----------------------------------------------------------------------

  lock_table_t<selop_which_t> locktab;
  
  tamed void 
  fdcb1 (int fd, selop which, evv_t cb)
  {
    tvars {
      ptr<lock_handle_t<selop_which_t> > lh;
      selop_which_t sw (fd, which);
    }

    twait { locktab.acquire (&lh, sw, lock_t::EXCLUSIVE, mkevent ()); }
    twait { fdcb (fd, which, mkevent ()); }
    fdcb (fd, which, NULL);
    lh->release ();
    cb->trigger ();
  }

  //-----------------------------------------------------------------------
  
  iofd_t::iofd_t (ptr<rcfd_t> fd, selop op)
    : _fd (fd), 
      _op (op), 
      _on (false) {}

  //-----------------------------------------------------------------------

  ptr<iofd_t>
  iofd_t::alloc (ptr<rcfd_t> fd, selop op)
  {
    return New refcounted<iofd_t> (fd, op);
  }
  
  //-----------------------------------------------------------------------

  iofd_t::~iofd_t ()
  {
    off ();
  }

  //-----------------------------------------------------------------------
  
  tamed void
  iofd_t::on (evv_t cb)
  {
    tvars {
      outcome_t oc (OUTCOME_SUCC);
      holdvar ptr<tame::iofd_t> hold (mkref (_self));
    }
    _on = true;
    twait { fdcb (fd (), _op, connector::cnc (mkevent (), cb, &oc)); }
    _on = false;
    
    if (oc != OUTCOME_CANCELLED) {
      cb->trigger ();
    }
    
    if (!_on) {
      off (false);
    }
  }

  //-----------------------------------------------------------------------

  void
  iofd_t::off (bool check)
  {
    if (_on || !check) {
      fdcb (fd (), _op, NULL);
      _on = false;
    }
  }

  //-----------------------------------------------------------------------

  rcfd_t::~rcfd_t ()
  {
    close (_fd);
  }

  //-----------------------------------------------------------------------

  ptr<rcfd_t> rcfd_t::alloc (int fd) { return New refcounted<rcfd_t> (fd); }

  //-----------------------------------------------------------------------

};
