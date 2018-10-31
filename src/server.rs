use neovim;
use neovim::session;

// TODO Connect should be std::net sockets and regexes.
// TODO Replace unwrap with some eprintln.

type HandlerFn = fn(Message) -> Result<neovim::Value, neovim::Value>;

pub fn start(handler: HandlerFn) {
    let mut session = session::Session::new_parent().expect("can't create neovim session");
    session.start_event_loop_handler(Handler::new(handler));
}

pub enum Message<'a> {
    Exit,
    Connect { addr: &'a str, expr: &'a str },
    Unknown(&'a str),
}

impl<'a> Message<'a> {
    fn from(name: &str, args: Vec<neovim::Value>) -> Message {
        match name {
            "exit" => Message::Exit,
            "connect" => Message::Connect {
                addr: args[0].as_str().unwrap(),
                expr: args[1].as_str().unwrap(),
            },
            _ => Message::Unknown(name),
        }
    }
}

struct Handler {
    handler: HandlerFn,
}

impl Handler {
    fn new(handler: HandlerFn) -> Handler {
        Handler { handler }
    }
}

impl neovim::Handler for Handler {
    fn handle_notify(&mut self, name: &str, args: Vec<neovim::Value>) {
        (self.handler)(Message::from(name, args)).unwrap();
    }

    fn handle_request(
        &mut self,
        name: &str,
        args: Vec<neovim::Value>,
    ) -> Result<neovim::Value, neovim::Value> {
        (self.handler)(Message::from(name, args))
    }
}