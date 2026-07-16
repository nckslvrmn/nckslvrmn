+++
title = 'Overwriting Shared Libraries in Aws Lambda'
date = '2020-05-18T23:26:39.047Z'
draft = false
tags = ["aws","serverless","ruby"]
+++

*Originally published on [DEV Community](https://dev.to/nckslvrmn/overwriting-shared-libraries-in-aws-lambda-479h).*

The latest Ruby runtime for AWS Lambda runs Ruby 2.7. Though this version of ruby is only 6 months old, the version of OpenSSL that Lambdas instance of Ruby was compiled with is over 3 years old. You can verify that by running the function below and seeing what it returns:

```ruby
require 'openssl'

def lambda_handler(event:, context:)
    return OpenSSL::OPENSSL_VERSION
end

# OpenSSL 1.0.2k  26 Jan 2017
```

That's Old! That means that Ruby's OpenSSL library is missing some key features like `SHA-3`, `TLS 1.3`, and the `scrypt` KDF.

I wanted to see if I could load in a newer version of the OpenSSL shared library ruby loads so I could leverage some of these shiny new features. Well, it turns out, [AWS Lambda Layers](https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html) was a big part of the answer here. In the documentation, a Lambda Layer is available to your Lambda code via the `/opt` directory. Now anyone who uses a lot of gem dependencies might have already come across this feature as it's a great way to share gems across different functions while keeping the function size itself fairly small.

But interestingly enough, it's not just a place to load gems. Lambda also adds to the `RUBYLIB` environment variable with a path you can fill with a Lambda Layer (specifically `/opt/ruby/lib`). This path is also *prefixed* to the `LOAD_PATH` variable. This is where things get interesting.

Now that we know we can load up a Lambda Layer with a shared library that will be part of the auto searched `LOAD_PATH`, we can construct a Lambda Layer with the necessary files to load our own version of OpenSSL. To do this, we need a newer instance of `openssl.so` that was compiled with Ruby and we also need the `libssl.so.1.1` and `libcrypto.so.1.1` files to support the shared library.

I was able to extract a copy of these files by installing the latest version of OpenSSL from my package manager (pacman), and installing Ruby 2.7 from RVM so it re-compiled on my machine. In the end, I constructed a directory structure that looked like this:

```bash
.
├── lib
│   ├── libcrypto.so -> libcrypto.so.1.1
│   ├── libcrypto.so.1.1
│   ├── libssl.so -> libssl.so.1.1
│   └── libssl.so.1.1
└── ruby
    └── lib
        └── openssl.so
```

I then zipped that up and uploaded that zip to a new Lambda Layer destined for my function. Upon running the below function, we can see that my OpenSSL version is now nice and new and should include the features I want! Running the original function above, I now see `OpenSSL 1.1.1d  10 Sep 2019`. Excellent! Now I can go generate all the `scrypt` keys and initiate all the `TLS 1.3` connections I want right?

Not exactly. It turns out, Ruby has a fun little behavior when it sees it needs to load some files. when calling `require`, ruby will search through the `LOAD_PATH` for the code you are trying to load, but specifically with `require`, it will load .rb files **and** shared libraries with the `.so` extension. So When I tried to create a new `SHA-256` digest, I was met with an unexpected error:

```ruby
require 'openssl'

def lambda_handler(event:, context:)
    return OpenSSL::Digest::SHA256.new
end

# uninitialized constant OpenSSL::Digest::SHA256
```

What happened? Well it turns out, because my `openssl.so` file is now *ahead* of Ruby's built-in `openssl.rb` code, I am only loading the shared library which comes with some classes, but not all the classes I  expect. To get around this, it's quite simple:

```ruby
require 'openssl.rb'

def lambda_handler(event:, context:)
    return OpenSSL::Digest::SHA256.new
end

# #<OpenSSL::Digest::SHA256: ...>
```

By specifying the `.rb` extension, I am now instructing Ruby to look through its `LOAD_PATH` until it finds the first instance of a file called `openssl.rb`. This is included with ruby and is the code that loads in all of the classes I expect to see, as well as an explicit call to load `openssl.so`. This now allows me to use all of the shiny new features that OpenSSL 1.1.1(x) provides without having to use a [Custom Runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html).