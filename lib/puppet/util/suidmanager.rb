require 'puppet/util/warnings'
require 'forwardable'
require 'etc'

module Puppet::Util::SUIDManager
  include Puppet::Util::Warnings
  extend Forwardable

  # Note groups= is handled specially due to a bug in OS X 10.6
  to_delegate_to_process = [ :euid=, :euid, :egid=, :egid, :uid=, :uid, :gid=, :gid, :groups ]

  to_delegate_to_process.each do |method|
    def_delegator Process, method
    module_function method
  end

  def osx_maj_ver
    return @osx_maj_ver unless @osx_maj_ver.nil?
    require 'facter'
    # 'kernel' is available without explicitly loading all facts
    if Facter.value('kernel') != 'Darwin'
      @osx_maj_ver = false
      return @osx_maj_ver
    end
    # But 'macosx_productversion_major' requires it.
    Facter.loadfacts
    @osx_maj_ver = Facter.value('macosx_productversion_major')
  end
  module_function :osx_maj_ver

  def groups=(grouplist)
    if osx_maj_ver == '10.6'
      return true
    else
      return Process.groups = grouplist
    end
  end
  module_function :groups=

  def self.root?
    Process.uid == 0
  end

  # Runs block setting uid and gid if provided then restoring original ids
  def asuser(new_uid=nil, new_gid=nil)
    return yield if Puppet.features.microsoft_windows?
    return yield unless root?
    return yield unless new_uid or new_gid

    old_euid, old_egid = self.euid, self.egid
    begin
      change_privileges(new_uid, new_gid, false)

      yield
    ensure
      change_privileges(new_uid ? old_euid : nil, old_egid, false)
    end
  end
  module_function :asuser

  def change_privileges(uid=nil, gid=nil, permanently=false)
    return unless uid or gid

    unless gid
      uid = convert_xid(:uid, uid)
      gid = Etc.getpwuid(uid).gid
    end

    change_group(gid, permanently)
    change_user(uid, permanently) if uid
  end
  module_function :change_privileges

  def change_group(group, permanently=false)
    gid = convert_xid(:gid, group)
    raise Puppet::Error, "No such group #{group}" unless gid

    if permanently
      begin
        Process::GID.change_privilege(gid)
      rescue NotImplementedError
        Process.egid = gid
        Process.gid  = gid
      end
    else
      Process.egid = gid
    end
  end
  module_function :change_group

  def change_user(user, permanently=false)
    uid = convert_xid(:uid, user)
    raise Puppet::Error, "No such user #{user}" unless uid

    if permanently
      begin
        Process::UID.change_privilege(uid)
      rescue NotImplementedError
        # If changing uid, we must be root. So initgroups first here.
        initgroups(uid)
        Process.euid = uid
        Process.uid  = uid
      end
    else
      # If we're already root, initgroups before changing euid. If we're not,
      # change euid (to root) first.
      if Process.euid == 0
        initgroups(uid)
        Process.euid = uid
      else
        Process.euid = uid
        initgroups(uid)
      end
    end
  end
  module_function :change_user

  # Make sure the passed argument is a number.
  def convert_xid(type, id)
    map = {:gid => :group, :uid => :user}
    raise ArgumentError, "Invalid id type #{type}" unless map.include?(type)
    ret = Puppet::Util.send(type, id)
    if ret == nil
      raise Puppet::Error, "Invalid #{map[type]}: #{id}"
    end
    ret
  end
  module_function :convert_xid

  # Initialize primary and supplemental groups to those of the target user.
  # We take the UID and manually look up their details in the system database,
  # including username and primary group.
  def initgroups(uid)
    pwent = Etc.getpwuid(uid)
    Process.initgroups(pwent.name, pwent.gid)
  end

  module_function :initgroups

  def run_and_capture(command, new_uid=nil, new_gid=nil)
    output = Puppet::Util.execute(command, :failonfail => false, :combine => true, :uid => new_uid, :gid => new_gid)
    [output, $CHILD_STATUS.dup]
  end
  module_function :run_and_capture
end

