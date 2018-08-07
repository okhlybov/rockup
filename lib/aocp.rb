=begin
Alternative Object Construction Path (AOCP)

Some Ruby magic to introduce object construction path alternative to the standard *::new* -> *#initialize* one.

==== Example

  require 'aocp'

  class MyClass
    
    extend AOCP

    def_ctor :my_new, :my_init do |arg|
      puts arg
    end

  end

  MyClass.my_new 3

Here *MyClass::my_new* creates an instance of *MyClass* and initializes it with *#my_init* instance method created with the body specified as the passed block to *#def_ctor* bypassing the default *#initialize* method.

=end
module AOCP

=begin
Define alternative object construction.
=end
  def def_ctor(new, initialize = :initialize, &block)
    instance_eval %{
      def self.#{new}(*args)
        obj = allocate
        obj.__send__(:#{initialize}, *args)
        obj
      end
    }
    define_method(initialize, &block) if block_given?
  end

end