require 'spec_helper'

module VSphereCloud
  describe Resources do
    subject(:resources) { VSphereCloud::Resources.new(datacenter, cluster_locality, config) }
    let(:cluster_locality) { instance_double(VSphereCloud::ClusterLocality) }
    let(:config) { instance_double('VSphereCloud::Config', client: client, logger: logger) }
    let(:client) { instance_double('VSphereCloud::Client') }
    let(:datacenter) { instance_double('VSphereCloud::Resources::Datacenter', name: 'datacenter_name') }
    let(:logger) { instance_double('Logger', info: nil, debug: nil) }

    describe :pick_persistent_datastore_in_cluster do
      let(:cluster) { double(:cluster) }
      before { allow(datacenter).to receive(:clusters).and_return({ "bar" => cluster }) }

      it "should return the datastore when it was placed successfully" do
        datastore = double(:datastore)
        expect(datastore).to receive(:allocate).with(1024)
        expect(cluster).to receive(:pick_persistent).with(1024).and_return(datastore)
        expect(resources.pick_persistent_datastore_in_cluster("bar", 1024)).
          to eq(datastore)
      end

      it "should return nil when it wasn't placed successfully" do
        expect(cluster).to receive(:pick_persistent).with(1024).and_return(nil)
        expect(resources.pick_persistent_datastore_in_cluster("bar", 1024)).
          to be_nil
      end
    end

    describe '#pick_cluster_for_vm' do
      let(:datastore1) { VSphereCloud::Resources::Datastore.new('name' => 'datastore1', 'summary.freeSpace' => (30 + Resources::DISK_HEADROOM) * Resources::BYTES_IN_MB) }
      let(:cluster1) { FakeCluster.new('cluster1', [datastore1], 10 + Resources::MEMORY_HEADROOM) }
      let(:cluster_locality) { VSphereCloud::ClusterLocality.new([cluster1]) }
      let(:requested_memory) { 0 }
      let(:requested_ephemeral_disk) { 5 }
      let(:existing_persistent_disks) { [] }

      it 'selects clusters that satisfy the requested memory and ephemeral disk size' do
        cluster = subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks)
        expect(cluster).to eq(cluster1)
      end

      context 'when no cluster satisfies the requested memory' do
        let(:requested_memory) { 11 }
        it 'raises' do
          expect { subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks) }.to raise_error
        end
      end

      context 'when no cluster satisfies the requested ephemeral disk' do
        let(:requested_ephemeral_disk) { 31 }
        it 'raises' do
          expect { subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks) }.to raise_error
        end
      end

      context 'with an existing persistent disk' do
        let(:disk) { VSphereCloud::Resources::Disk.new('disk1', 20, datastore1, 'path') }
        let(:existing_persistent_disks) { [] }

        context 'when disk is in a cluster that satisfies requirements' do
          it 'returns cluster that has disk' do
            cluster = subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks)
            expect(cluster).to eq(cluster1)
          end
        end
      end

      context 'with multiple clusters' do
        let(:datastore2) { VSphereCloud::Resources::Datastore.new('name' => 'datastore2', 'summary.freeSpace' => (datastore2_free_space + Resources::DISK_HEADROOM) * Resources::BYTES_IN_MB) }
        let(:datastore2_free_space) { 80 }
        let(:cluster2) { FakeCluster.new('cluster2', [datastore2], 12 + Resources::MEMORY_HEADROOM) }
        let(:cluster_locality) { VSphereCloud::ClusterLocality.new([cluster1, cluster2]) }

        it 'selects randomly from the clusters that satisfy the requested memory and ephemeral disk size' do
          expect(Resources::Util).to receive(:weighted_random).with([[cluster2, 16], [cluster1, 6]]).and_return(cluster2)
          cluster = subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks)
          expect(cluster).to eq(cluster2)
        end

        context 'with an existing persistent disks' do
          let(:disk1) { VSphereCloud::Resources::Disk.new('disk1', 10, datastore1, 'path1') }
          let(:disk2) { VSphereCloud::Resources::Disk.new('disk2', 20, datastore2, 'path2') }
          let(:existing_persistent_disks) { [disk1, disk2] }

          context 'when all clusters satisfy requirements' do
            it 'returns cluster that has more persistent disk sizes' do
              cluster = subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks)
              expect(cluster).to eq(cluster2)
            end
          end

          context 'when cluster with most disks does not satisfy requirements' do
            let(:requested_memory) { 11 }
            it 'returns next cluster with most disks that satisfy requirement' do
              cluster = subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks)
              expect(cluster).to eq(cluster2)
            end
          end

          context 'when disk belongs to two clusters' do
            let(:datastore3) { VSphereCloud::Resources::Datastore.new('name' => 'datastore3', 'summary.freeSpace' => (50 + Resources::DISK_HEADROOM) * Resources::BYTES_IN_MB) }
            let(:cluster3) { FakeCluster.new('cluster3', [datastore1, datastore3], 10 + Resources::MEMORY_HEADROOM) }
            let(:cluster_locality) { VSphereCloud::ClusterLocality.new([cluster1, cluster2, cluster3]) }

            let(:disk1) { VSphereCloud::Resources::Disk.new('disk1', 10, datastore1, 'path1') }
            let(:disk2) { VSphereCloud::Resources::Disk.new('disk2', 50, datastore2, 'path2') }
            let(:disk3) { VSphereCloud::Resources::Disk.new('disk3', 30, datastore3, 'path3') }

            let(:existing_persistent_disks) { [disk1, disk2, disk3] }

            context 'when cluster with biggest disks size cannot fit other disks' do
              let(:datastore2_free_space) { 5 }

              context 'when next cluster with most disks can fit the disk that is not in that cluster' do
                it 'returns next cluster with most disks that satisfy requirement' do
                  cluster = subject.pick_cluster_for_vm(requested_memory, requested_ephemeral_disk, existing_persistent_disks)
                  expect(cluster).to eq(cluster3)
                end
              end
            end
          end
        end
      end
    end

    describe 'pick_ephemeral_datastore' do
      let(:cluster) { instance_double(VSphereCloud::Resources::Cluster, name: 'awesome cluster') }
      let(:datastore) { instance_double(VSphereCloud::Resources::Datastore, allocate: nil) }

      before { allow(cluster).to receive(:pick_ephemeral).with(1024).and_return(datastore) }

      it 'picks ephemeral datastore in cluster' do
        expect(resources.pick_ephemeral_datastore(cluster, 1024)).to eq(datastore)
      end

      it 'allocates disk size in datastore' do
        resources.pick_ephemeral_datastore(cluster, 1024)
        expect(datastore).to have_received(:allocate).with(1024)
      end

      context 'when cluster does not have datastore to satisfy disk size requirement' do
        before { allow(cluster).to receive(:pick_ephemeral).with(1024).and_return(nil) }
        it 'raises Bosh::Clouds::NoDiskSpace' do
          expect {
            resources.pick_ephemeral_datastore(cluster, 1024)
          }.to raise_error Bosh::Clouds::NoDiskSpace
        end
      end
    end

    describe 'pick_persistent_datastore' do
      let(:cluster) { instance_double(VSphereCloud::Resources::Cluster, name: 'awesome cluster') }
      let(:datastore) { instance_double(VSphereCloud::Resources::Datastore, allocate: nil) }

      before { allow(cluster).to receive(:pick_persistent).with(1024).and_return(datastore) }

      it 'picks persistent datastore in cluster' do
        expect(resources.pick_persistent_datastore(cluster, 1024)).to eq(datastore)
      end

      it 'allocates disk size in datastore' do
        resources.pick_persistent_datastore(cluster, 1024)
        expect(datastore).to have_received(:allocate).with(1024)
      end

      context 'when cluster does not have datastore to satisfy disk size requirement' do
        before { allow(cluster).to receive(:pick_persistent).with(1024).and_return(nil) }
        it 'raises Bosh::Clouds::NoDiskSpace' do
          expect {
            resources.pick_persistent_datastore(cluster, 1024)
          }.to raise_error Bosh::Clouds::NoDiskSpace
        end
      end
    end
  end
end
